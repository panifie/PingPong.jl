using SimMode.Executors: st, Instances, OptSetup, OptRun, OptScore, Context
using SimMode.TimeTicks
using .Instances: value
using .Instances.Data: DataFrame, save_data, load_data, nrow, zilmdb, todata, tobytes
using .Instances.Data.Zarr: getattrs, writeattrs
using .st: Strategy, Sim, SimStrategy, WarmupPeriod
using SimMode.Misc: DFT
using SimMode.Lang: Option, splitkws
using Stats.Statistics: median
using BlackBoxOptim
import BlackBoxOptim: bboptimize
import .st: ping!

const ContextSpace = NamedTuple{(:ctx, :space),Tuple{Context,Any}}
mutable struct OptRunning
    @atomic value::Bool
end
const RUNNING = OptRunning(false)
running!() = @atomic RUNNING.value = true
stopping!() = @atomic RUNNING.value = false
isrunning() = @atomic RUNNING.value

@doc "Has to return a `Optimizations.ContextSpace` named tuple where `ctx` (`Executors.Context`) is the time period to backtest and the `space` is
either an already constructed subtype of `BlackBoxOptim.SearchSpace` or a tuple (`Symbol`, args...) for a search space pre-defined within the BBO package.
"
ping!(::Strategy, ::OptSetup) = error("not implemented")

@doc "This ping function should apply the parameters to the strategy, called before the backtest is performed. "
ping!(::Strategy, params, ::OptRun) = error("not implemented")

#TYPENUM
@doc "An optimization session stores all the evaluated parameters combinations."
struct OptSession17{S<:SimStrategy,N}
    s::S
    ctx::Context{Sim}
    params::T where {T<:NamedTuple}
    opt_config::Any
    results::DataFrame
    best::Ref{Any}
    lock::ReentrantLock
    s_clones::NTuple{N,Tuple{ReentrantLock,S}}
    ctx_clones::NTuple{N,Context{Sim}}
    function OptSession17(
        s::Strategy; ctx, params, opt_config=Dict(), n_threads=Threads.nthreads()
    )
        s_clones = tuple(((ReentrantLock(), similar(s)) for _ in 1:n_threads)...)
        ctx_clones = tuple((similar(ctx) for _ in 1:n_threads)...)
        new{typeof(s),n_threads}(
            s,
            ctx,
            params,
            opt_config,
            DataFrame(),
            Ref(nothing),
            ReentrantLock(),
            s_clones,
            ctx_clones,
        )
    end
end

OptSession = OptSession17

_shortdate(date) = Dates.format(date, dateformat"yymmdd")
function session_key(sess::OptSession)
    params_part = join(first.(string.(keys(sess.params))))
    ctx_part =
        ((_shortdate(getproperty(sess.ctx.range, p)) for p in (:start, :stop))...,) |>
        x -> join(x, "-")
    s_part = string(nameof(sess.s))
    config_part = first(string(hash(sess.params) + hash(sess.opt_config)), 4)
    join((s_part, ctx_part, params_part * config_part), "/"),
    (; s_part, ctx_part, params_part, config_part)
end

@doc "Save the optimization session over the provided zarr instance.

`sess`: the `OptSession`
`from`: save the optimization results starting from the specified index (when saving progressively)
`to`: save the optimization results up to the specified index (when saving progressively)
"
function save_session(sess::OptSession; from=0, to=nrow(sess.results), zi=zilmdb())
    k, parts = session_key(sess)
    if from == 0
        let z = load_data(zi, k; serialized=true, as_z=true)[1], attrs = z.attrs
            attrs["name"] = parts.s_part
            attrs["startstop"] = parts.ctx_part
            attrs["params_k"] = parts.params_part
            attrs["code"] = parts.config_part
            attrs["ctx"] = tobytes(sess.ctx)
            attrs["params"] = tobytes(sess.params)
            attrs["opt_config"] = tobytes(sess.opt_config)
            writeattrs(z.storage, z.path, z.attrs)
        end
    end
    # let z = load_data(zi, k; serialized=true, as_z=true)[1]
    #     if !isempty(z)
    #         @assert DateTime(from) > todata(z[end, 1]) (from, DateTime(from), todata(z[end, 1]))
    #     end
    # end
    save_data(
        zi,
        k,
        [(DateTime(from), @view(sess.results[max(1, from):to, :]))];
        chunk_size=(256, 2),
        serialize=true,
    )
end

function rgx_key(name, startstop, params_k, code)
    Regex("$name/$startstop/$params_k$code")
end

_deserattrs(attrs, k) = convert(Vector{UInt8}, attrs[k]) |> todata
@doc "Load an optimization session from storage, name:
- `name`: strategy name
- `start/stop`: start and stop date of the backtesting context
- `params_k`: the first letter of every param (`first.(string.(keys(sess.params)))`)
- `code`: hash of `params` and `opt_config` truncated to 4 chars.

Only the strategy name is required, rest is optional.
"
function load_session(
    name,
    startstop=".*",
    params_k=".*",
    code="";
    zi=zilmdb(),
    as_z=false,
    results_only=false,
)
    load(k) = load_data(zi, k; serialized=true, as_z=true)[1]
    function results!(df, z)
        for row in eachrow(z)
            append!(df, todata(row[2]))
        end
        df
    end
    function session(z)
        as_z && return z
        results_only && return results!(DataFrame(), z)
        sess = let attrs = z.attrs
            @assert isempty(z) || !isempty(attrs) "ZArray should contain session attributes."
            OptSession(
                st.strategy(Symbol(attrs["name"]));
                ctx=_deserattrs(attrs, "ctx"),
                params=_deserattrs(attrs, "params"),
                opt_config=_deserattrs(attrs, "opt_config"),
            )
        end
        results!(sess.results, z)
        return sess
    end
    z = if all((x -> x != ".*").((name, startstop, params_k, code)))
        k = join((name, "$startstop", "$params_k$code"), "/")
        z = load(k)
    else
        rgx = rgx_key(name, startstop, params_k, code)
        arrs = filter(k -> occursin(rgx, k), keys(zi.group.arrays))
        if length(arrs) == 0
            parts = ((k for k in (name, startstop, params_k, code) if k != ".*")...,)
            throw(KeyError(parts))
        elseif length(arrs) == 1
            k = first(arrs)
            load(first(arrs))
        else
            error("Choose a key more specific among $arrs")
        end
    end
    return session(z)
end

function load_session(sess::OptSession, args...; kwargs...)
    load_session(values(session_key(sess)[2])..., args...; kwargs...)
end

function ctxsteps(ctx, repeats)
    small_step = Millisecond(ctx.range.step).value
    big_step = let timespan = Millisecond(ctx.range.stop - ctx.range.start).value
        Millisecond(round(Int, timespan / max(1, repeats - 1)))
    end
    (; small_step, big_step)
end

function define_backtest_func(sess, small_step, big_step)
    (params, n) -> let tid = Threads.threadid(), slot = sess.s_clones[tid]
        lock(slot[1]) do
            let s = slot[2], ctx = sess.ctx_clones[tid]
                # clear strat
                st.sizehint!(s) # avoid deallocations
                st.reset!(s, true)
                # apply params
                ping!(s, params, OptRun())
                # randomize strategy startup time
                let wp = ping!(s, WarmupPeriod()),
                    inc = Millisecond(round(Int, small_step / n)) + big_step * (n - 1)

                    current!(ctx.range, ctx.range.start + wp + inc)
                end
                # backtest and score
                backtest!(s, ctx; doreset=false)
                obj = ping!(s, OptScore())
                # record run
                cash = value(st.current_total(s))
                trades = st.trades_count(s)
                lock(sess.lock) do
                    push!(
                        sess.results,
                        (;
                            repeat=n,
                            obj,
                            cash,
                            trades,
                            (
                                pname => p for (pname, p) in zip(keys(sess.params), params)
                            )...,
                        ),
                    )
                end
                obj
            end
        end
    end
end

@doc "Multi(threaded) optimization function."
function _multi_opt_func(repeats, backtest_func, median_func, obj_type)
    (params) -> begin
        job(n) = backtest_func(params, n)
        scores = Vector{obj_type}(undef, repeats)
        Threads.@threads for n in 1:repeats
            if isrunning()
                scores[n] = job(n)
            end
        end

        mapreduce(permutedims, vcat, scores) |> median_func
    end
end

@doc "Single(threaded) optimization function."
function _single_opt_func(repeats, backtest_func, median_func, args...)
    (params) -> begin
        mapreduce(permutedims, vcat, [(backtest_func(params, n) for n in 1:repeats)...]) |> median_func
    end
end

@doc "The median in multi(objective) mode has to be applied over all the (repeated) iterations."
function define_median_func(ismulti)
    if ismulti
        (x) -> tuple(median(x; dims=1)...)
    else
        (x) -> (median(x),)
    end
end

function define_opt_func(
    s::Strategy; backtest_func, ismulti, repeats, obj_type, isthreaded=isthreadsafe(s)
)
    median_func = define_median_func(ismulti)
    opt_func = isthreaded ? _multi_opt_func : _single_opt_func
    opt_func(repeats, backtest_func, median_func, obj_type)
end

@doc "Returns the number of objectives and their type."
function objectives(s)
    let test_obj = ping!(s, OptScore())
        typeof(test_obj), length(test_obj)
    end
end

@doc "Fetch the named tuple of a single parameters combination."
function result_params(sess::OptSession, idx=nrow(sess.results))
    iszero(idx) && return nothing
    row = sess.results[idx, :]
    (; (k => getproperty(row, k) for k in keys(sess.params))...)
end

function log_path(s, name=split(string(now()), ".")[1])
    dirpath = joinpath(realpath(dirname(s.path)), "logs", "opt", string(nameof(s)))
    joinpath(dirpath, name * ".log"), dirpath
end

function logs(s)
    dirpath = log_path(s, "")[2]
    joinpath.(dirpath, readdir(dirpath))
end

function logs_clear(s)
    dirpath = log_path(s, "")[2]
    for f in readdir(dirpath)
        rm(joinpath(dirpath, f); force=true)
    end
end

function print_log(s, idx=nothing)
    let logs = logs(s)
        println(read(logs[@something idx lastindex(logs)], String))
    end
end

export OptSession

include("bbopt.jl")
include("grid.jl")
