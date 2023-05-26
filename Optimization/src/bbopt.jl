using SimMode.TimeTicks: current!
using SimMode: backtest!
using Random

## kwargs: @doc Optimization.BlackBoxOptim.OptRunController
## all BBO methods: `BlackBoxOptim.SingleObjectiveMethods`
## compare different optimizers  `BlackBoxOptim.compare_optimizers(...)`
#
const disabled_methods = Set((
    :simultaneous_perturbation_stochastic_approximation,
    :resampling_memetic_search,
    :resampling_inheritance_memetic_search,
))

@doc "Get a filtered list of methods supported by BBO."
function bbomethods()
    collect(k for k in keys(BlackBoxOptim.SingleObjectiveMethods) if k ∉ disabled_methods)
end

_tsaferesolve(v::Ref{Bool}) = v[]
_tsaferesolve(v::Bool) = v
isthreadsafe(s::Strategy) = _tsaferesolve(s.self.THREADSAFE)

function ctxfromstrat(s)
    ctx, s_space = ping!(s, OptSetup())
    ctx,
    if s_space isa SearchSpace
        s_spac
    elseif s_space isa Function
        s_space()
    else
        let error_msg = "Wrong optimization parameters, pass either a value of type <: `SearchSpace` or a tuple where the first element is the BBO space type and the rest is the argument for the space constructor."
            @assert typeof(s_space) <: Union{Tuple,Vector} error_msg
            @assert length(s_space) > 0 && s_space[1] isa Symbol
            getglobal(BlackBoxOptim, s_space[1])(s_space[2:end]...)
        end
    end
end

@doc """ Optimize parameters using the BlackBoxOptim package.

- `repeats`: how many times to run the backtest for each step
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
function bboptimize(s::Strategy{Sim}; seed=1, repeats=1, kwargs...)
    Random.seed!(seed)
    let n_jobs = get(kwargs, :NThreads, 1)
        @assert n_jobs == 1 "Multithreaded mode not supported."
        # @assert isthreadsafe(s) || n_jobs == 1 "Optimization is multi-threaded. Ensure the strategy $(nameof(s)) is thread safe and set the global constant `THREADSAFE` to `Ref(true)` in the strategy module or set `n_jobs` to 1"
        @assert n_jobs <= Threads.nthreads() - 1 "Should not use more threads than logical cores $(Threads.nthreads())."
        @assert :Workers ∉ keys(kwargs) "Multiprocess evaluation using `Distributed` not supported because of python."
    end
    ctx, space = ctxfromstrat(s)
    sess = OptSession(s, ctx, space)
    function onerun(params, n)
        ping!(s, params, OptRun())
        st.reset!(s)
        let wp = ping!(s, WarmupPeriod())
            current!(ctx.range, ctx.range.start + wp + ctx.range.step * n)
        end
        backtest!(s, ctx; doreset=false)
        obj = ping!(s, OptScore())
        cash = value(st.current_total(s))
        trades = st.trades_total(s)
        push!(
            sess.results,
            (; obj, cash, trades, (Symbol("x$n") => p for (n, p) in enumerate(params))...),
        )
        obj
    end
    optrun(params) = median(((onerun(params, n) for n in 1:repeats)...,))
    try
        filtered, rest = splitkws(:MaxStepsWithoutProgress; kwargs)
        MaxStepsWithoutProgress = if isempty(filtered)
            max(3, Threads.nthreads())
        else
            first(filtered)[2]
        end
        r = bboptimize(optrun; SearchSpace=space, MaxStepsWithoutProgress, rest...)
        sess.best[] = best_candidate(r)
    catch e
        showerror(stdout, e)
    end
    sess
end

export OptimizationContext
export optimize, best_fitness, best_candidate
