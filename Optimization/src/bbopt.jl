using SimMode.TimeTicks: current!
using SimMode: start!
using Random
using BlackBoxOptim
import BlackBoxOptim: bboptimize
using SimMode.Lang: @debug_backtrace

## kwargs: @doc Optimization.BlackBoxOptim.OptRunController
## all BBO methods: `BlackBoxOptim.SingleObjectiveMethods`
## compare different optimizers  `BlackBoxOptim.compare_optimizers(...)`
#
const disabled_methods = Set((
    :simultaneous_perturbation_stochastic_approximation,
    :resampling_memetic_search,
    :resampling_inheritance_memetic_search,
))

@doc "Get a filtered list of methods supported by BBO (single or multi)."
function bbomethods(multi=false)
    Set(
        k for k in keys(
            getglobal(
                BlackBoxOptim,
                ifelse(multi, :MultiObjectiveMethods, :SingleObjectiveMethods),
            ),
        ) if k ∉ disabled_methods
    )
end

_tsaferesolve(v::Ref{Bool}) = v[]
_tsaferesolve(v::Bool) = v
isthreadsafe(s::Strategy) =
    if isdefined(s.self, :THREADSAFE)
        _tsaferesolve(s.self.THREADSAFE)
    else
        false
    end

function ctxfromstrat(s)
    ctx, params, s_space = ping!(s, OptSetup())
    ctx,
    params,
    s_space,
    if s_space isa SearchSpace
        s_space
    elseif s_space isa Function
        s_space()
    else
        let error_msg = "Wrong optimization parameters, pass either a value of type <: `SearchSpace` or a tuple where the first element is the BBO space type and the rest is the argument for the space constructor."
            @assert typeof(s_space) <: Union{NamedTuple,Tuple,Vector} error_msg
            @assert length(s_space) > 0 && s_space[1] isa Symbol
            lower, upper = lowerupper(params)
            args = hasproperty(s_space, :precision) ? (s_space.precision,) : ()
            getglobal(BlackBoxOptim, s_space.kind)(lower, upper, args...)
        end
    end
end

function _spacedims(params)
    @assert length(params) > 2 "Params second and third element should be lower and upper bounds arrays."
    lower = params[2]
    upper = params[3]
    @assert length(lower) == length(upper) "Params lower and upper bounds do not match in length."
    length(lower)
end

function fitness_scheme(s::Strategy, n_obj)
    let weightsfunc = get(s.attrs, :opt_weighted_fitness, missing)
        ParetoFitnessScheme{n_obj}(;
            is_minimizing=false,
            (weightsfunc isa Function ? (; aggregator=weightsfunc) : ())...,
        )
    end
end

@doc """ Optimize parameters using the BlackBoxOptim package.

- `splits`: how many times to run the backtest for each step
- `seed`: random seed
- `kwargs`: The arguments to pass to the underlying BBO function. See the docs for the BlackBoxOptim package. Here are some most common parameters:
  - `MaxTime`: max evaluation time for the optimization
  - `MaxFuncEvals`: max number of function (backtest) evaluation
  - `TraceMode`: (:silent, :compact, :verbose) controls the logging
  - `MaxSteps`, `MaxStepsWithoutProgress`

From within your strategy define four `ping!` functions:
- `ping!(::Strategy, ::OptSetup)`: for the period of time to evaluate and the parameters space for the optimization..
- `ping!(::Strategy, params, ::OptRun)`: called before running the backtest, should apply the parameters to the strategy
"""
function bboptimize(
    s::Strategy{Sim};
    seed=1,
    splits=1,
    resume=true,
    save_freq=nothing,
    zi=zilmdb(),
    kwargs...,
)
    running!()
    Random.seed!(seed)
    let n_jobs = get(kwargs, :NThreads, 1)
        @assert n_jobs == 1 "Multithreaded mode not supported."
        # @assert isthreadsafe(s) || n_jobs == 1 "Optimization is multi-threaded. Ensure the strategy $(nameof(s)) is thread safe and set the global constant `THREADSAFE` to `Ref(true)` in the strategy module or set `n_jobs` to 1"
        @assert n_jobs <= max(1, Threads.nthreads() - 1) "Should not use more threads than logical cores $(Threads.nthreads())."
        @assert :Workers ∉ keys(kwargs) "Multiprocess evaluation using `Distributed` not supported because of python."
    end
    local ctx, params, s_space, space, sess
    try
        ctx, params, s_space, space = ctxfromstrat(s)
        sess = OptSession(s; ctx, params, attrs=Dict{Symbol,Any}(pairs((; s_space))))
        resume && resume!(sess; zi)
    catch
        @debug_backtrace
        if isinteractive()
            let resp = Base.prompt(
                    "Can't resume the session. Continue? [y/n] (pass resume=false to skip this)",
                )
                if startswith(resp, "n")
                    return nothing
                end
            end
        end
        ctx, params, s_space, space = ctxfromstrat(s)
        sess = OptSession(s; ctx, params, attrs=Dict{Symbol,Any}(pairs((; s_space))))
    end
    from = Ref(nrow(sess.results) + 1)
    save_args = if !isnothing(save_freq)
        resume || save_session(sess; zi)
        (;
            CallbackFunction=(_...) -> begin
                save_session(sess; from=from[], zi)
                from[] = nrow(sess.results) + 1
            end,
            CallbackInterval=Millisecond(save_freq).value / 1000.0,
        )
    else
        ()
    end
    backtest_func = define_backtest_func(sess, ctxsteps(ctx, splits)...)
    obj_type, n_obj = objectives(s)

    filtered, rest = let (filtered, rest) = splitkws(:MaxStepsWithoutProgress; kwargs)
        filtered, Dict{Symbol,Any}(rest)
    end
    ismulti = let mt = get(rest, :Method, :xnes)
        flag = n_obj > 1
        @assert mt ∈ bbomethods(flag) "Optimization method incompatible."
        flag
    end
    opt_func = define_opt_func(s; backtest_func, ismulti, splits, obj_type)
    r = opt = nothing
    try
        rest[:MaxStepsWithoutProgress] = if isempty(filtered)
            max(10, Threads.nthreads() * 10)
        else
            first(filtered)[2]
        end
        if ismulti
            rest[:FitnessScheme] = fitness_scheme(s, n_obj)
        end
        initials = if isempty(sess.results)
            ()
        else
            (
                let df = sort(sess.results, :obj)
                    # :borg_mea only supports one initial comb
                    cols = collect(keys(sess.params))
                    if ismulti
                        row = @view df[end, cols]
                        collect(row)
                    else
                        rows = @view df[(end - 9):end, cols]
                        collect.(eachrow(rows))
                    end
                end,
            )
        end
        runner(args...; kwargs...) = @nogc opt_func(args...; kwargs...)
        opt = bbsetup(runner; SearchSpace=space, save_args..., rest...)
        r = bboptimize(opt, initials...)
        sess.best[] = best_candidate(r)
    catch e
        stopping!()
        Base.show_backtrace(stdout, catch_backtrace())
        save_session(sess; from=from[], zi)
        e isa InterruptException || showerror(stdout, e)
    end
    stopping!()
    sess, (; opt, r)
end

export OptimizationContext
export bboptimize, best_fitness, best_candidate
