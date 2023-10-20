using SimMode.Executors: st, Instances, OptSetup, OptRun, OptScore, Context
using SimMode.TimeTicks
using .Instances: value
using .Instances.Data: DataFrame, Not, save_data, load_data, nrow, todata, tobytes
using .Instances.Data: zilmdb, za
using .Instances.Data.Zarr: getattrs, writeattrs
using .Instances.Exchanges.Python.PythonCall.GC: enable as gc_enable, disable as gc_disable
using .Instances.Exchanges: exc, sb_exchanges
using .st: Strategy, Sim, SimStrategy, WarmupPeriod
using SimMode.Misc: DFT
using SimMode.Lang: Option, splitkws
using Stats.Statistics: median, mean
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
struct OptSession18{S<:SimStrategy,N}
    s::S
    ctx::Context{Sim}
    params::T where {T<:NamedTuple}
    attrs::Dict{Symbol,Any}
    results::DataFrame
    best::Ref{Any}
    lock::ReentrantLock
    s_clones::NTuple{N,Tuple{ReentrantLock,S}}
    ctx_clones::NTuple{N,Context{Sim}}
    function OptSession18(
        s::Strategy; ctx, params, offset=0, attrs=Dict(), n_threads=Threads.nthreads()
    )
        s_clones = tuple(
            ((ReentrantLock(), similar(s; mode=Sim())) for _ in 1:n_threads)...
        )
        ctx_clones = tuple((similar(ctx) for _ in 1:n_threads)...)
        attrs[:offset] = offset
        new{typeof(s),n_threads}(
            s,
            ctx,
            params,
            attrs,
            DataFrame(),
            Ref(nothing),
            ReentrantLock(),
            s_clones,
            ctx_clones,
        )
    end
end

OptSession = OptSession18

function Base.show(io::IO, sess::OptSession)
    w(args...) = write(io, string(args...))
    w("Optimization Session: ", nameof(sess.s))
    range = sess.ctx.range
    w("\nTest range: ", range.start, "..", range.stop, " (", range.step, ")")
    if length(sess.params) > 0
        w("\nParams: ")
        params = keys(sess.params)
        w((string(k, ", ") for k in params[begin:(end - 1)])..., params[end])
        w(" (", length(Iterators.product(values(sess.params)...)), ")")
    end
    w("\nConfig: ")
    config = collect(pairs(sess.attrs))
    for (k, v) in config[begin:(end - 1)]
        w(k, "(", v, "), ")
    end
    k, v = config[end]
    w(k, "(", v, ")")
end

_shortdate(date) = Dates.format(date, dateformat"yymmdd")
function session_key(sess::OptSession)
    params_part = join(first.(string.(keys(sess.params))))
    ctx_part =
        ((_shortdate(getproperty(sess.ctx.range, p)) for p in (:start, :stop))...,) |>
        x -> join(x, "-")
    s_part = string(nameof(sess.s))
    config_part = first(string(hash(tobytes(sess.params)) + hash(tobytes(sess.attrs))), 4)
    join(("Opt", s_part, string(ctx_part, ":", params_part, config_part)), "/"),
    (; s_part, ctx_part, params_part, config_part)
end

function zgroup_opt(zi)
    if za.is_zgroup(zi.store, "Opt")
        za.zopen(zi.store, "w"; path="Opt")
    else
        try
            za.zgroup(zi.store, "Opt")
        catch e
            if occursin("not empty", e.msg)
                if startswith(Base.prompt("Store not empty, reset? y/[n]"), "y")
                    delete!(zi.store, "Opt")
                    za.zgroup(zi.store, "Opt")
                else
                    rethrow()
                end
            else
                rethrow()
            end
        end
    end
end

function zgroup_strategy(zi, s_name::String)
    opt_group = zgroup_opt(zi)
    s_group = if za.is_zgroup(zi.store, "Opt/$s_name")
        opt_group.groups[s_name]
    else
        za.zgroup(opt_group, s_name)
    end
    (; s_group, opt_group)
end

zgroup_strategy(zi, s::Strategy) = zgroup_strategy(zi, string(nameof(s)))

@doc "Save the optimization session over the provided zarr instance.

`sess`: the `OptSession`
`from`: save the optimization results starting from the specified index (when saving progressively)
`to`: save the optimization results up to the specified index (when saving progressively)
"
function save_session(sess::OptSession; from=0, to=nrow(sess.results), zi=zilmdb())
    k, parts = session_key(sess)
    # ensure zgroup
    zgroup_strategy(zi, sess.s)
    if from == 0
        let z = load_data(zi, k; serialized=true, as_z=true)[1], attrs = z.attrs
            attrs["name"] = parts.s_part
            attrs["startstop"] = parts.ctx_part
            attrs["params_k"] = parts.params_part
            attrs["code"] = parts.config_part
            attrs["ctx"] = tobytes(sess.ctx)
            attrs["params"] = tobytes(sess.params)
            attrs["attrs"] = tobytes(sess.attrs)
            writeattrs(z.storage, z.path, z.attrs)
        end
    end
    save_data(
        zi,
        k,
        [(DateTime(from), @view(sess.results[max(1, from):to, :]))];
        chunk_size=(256, 2),
        serialize=true,
    )
end

function rgx_key(name, startstop, params_k, code)
    Regex("$name/$startstop:$params_k$code")
end

function anyexc()
    if nameof(exc) == Symbol()
        if isempty(sb_exchanges)
            :binance
        else
            first(keys(sb_exchanges))
        end
    else
        nameof(exc)
    end
end

_deserattrs(attrs, k) = convert(Vector{UInt8}, attrs[k]) |> todata
@doc "Load an optimization session from storage, name:
- `name`: strategy name
- `start/stop`: start and stop date of the backtesting context
- `params_k`: the first letter of every param (`first.(string.(keys(sess.params)))`)
- `code`: hash of `params` and `attrs` truncated to 4 chars.

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
    s=nothing,
)
    load(k) = begin
        load_data(zi, k; serialized=true, as_z=true)[1]
    end
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
            @assert !isempty(attrs) "ZArray should contain session attributes."
            OptSession(
                @something s st.strategy(
                    Symbol(attrs["name"]); exchange=anyexc(), mode=Sim()
                );
                ctx=_deserattrs(attrs, "ctx"),
                params=_deserattrs(attrs, "params"),
                attrs=_deserattrs(attrs, "attrs"),
            )
        end
        results!(sess.results, z)
        return sess
    end
    z = if all((x -> x != ".*").((name, startstop, params_k, code)))
        k = "Opt/$name/$startstop:$params_k$code"
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
    load_session(values(session_key(sess)[2])..., args...; sess.s, kwargs...)
end

function load_session(s::Strategy)
    load_session(string(nameof(s)), s)
end

function ctxsteps(ctx, repeats)
    small_step = Millisecond(ctx.range.step).value
    big_step = let timespan = Millisecond(ctx.range.stop - ctx.range.start).value
        Millisecond(round(Int, timespan / max(1, repeats - 1)))
    end
    (; small_step, big_step)
end

metrics_func(s; initial_cash) = begin
    obj = ping!(s, OptScore())
    # record run
    cash = value(st.current_total(s))
    pnl = cash / initial_cash - 1.0
    trades = st.trades_count(s)
    (; obj, cash, pnl, trades)
end

function define_backtest_func(sess, small_step, big_step)
    (params, n) -> let tid = Threads.threadid(), slot = sess.s_clones[tid]
        lock(slot[1]) do
            # `ofs` is used as custom input source of randomness
            let s = slot[2], ctx = sess.ctx_clones[tid], ofs = sess.attrs[:offset] + n
                # clear strat
                st.reset!(s, true)
                # apply params
                ping!(s, params, OptRun())
                # randomize strategy startup time
                let wp = ping!(s, WarmupPeriod()),
                    inc = Millisecond(round(Int, small_step / ofs)) + big_step * (n - 1)

                    current!(ctx.range, ctx.range.start + wp + inc)
                end
                # backtest and score
                initial_cash = value(s.cash)
                start!(s, ctx; doreset=false)
                st.sizehint!(s) # avoid deallocations
                metrics = metrics_func(s; initial_cash)
                lock(sess.lock) do
                    push!(
                        sess.results,
                        (;
                            repeat=ofs,
                            metrics...,
                            (
                                pname => p for (pname, p) in zip(keys(sess.params), params)
                            )...,
                        ),
                    )
                end
                metrics.obj
            end
        end
    end
end

@doc """ Disables pythoncall gc calls


"""
macro nogc(expr)
    ex = quote
        try
            $(gc_disable)()
            $expr
        finally
            $(gc_enable)()
        end
    end
    esc(ex)
end
@doc "Multi(threaded) optimization function."
function _multi_opt_func(repeats, backtest_func, median_func, obj_type)
    (params) -> @nogc begin
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
    (params) -> @nogc begin
        mapreduce(permutedims, vcat, [(backtest_func(params, n) for n in 1:repeats)...]) |> median_func
    end
end

@doc "The median in multi(objective) mode has to be applied over all the (repeated) iterations."
function define_median_func(ismulti)
    if ismulti
        (x) -> tuple(median(x; dims=1)...)
    else
        (x) -> median(x)
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
    isdir(dirpath) || mkpath(dirpath)
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
        isempty(logs) && error("no logs found for strategy $(nameof(s))")
        println(read(logs[@something idx lastindex(logs)], String))
    end
end

maybereduce(v::AbstractVector, f::Function) = f(v)
maybereduce(v, _) = v
function agg(f, sess::OptSession)
    gd = groupby(sess.results, [keys(sess.params)...])
    combine(gd, f; renamecols=false)
end
function agg(sess::OptSession; reduce_func=mean, agg_func=median)
    agg(
        (
            Not([keys(sess.params)..., :repeat]) .=>
                x -> maybereduce(x, reduce_func) |> agg_func
        ),
        sess,
    )
end

function optsessions(s::Strategy; zi=zilmdb())
    optsessions(string(nameof(s)); zi)
end

@doc "Returns the zarrays storing all the optimization session over the specified zarrinstance."
function optsessions(s_name::String; zi=zilmdb())
    opt_group = zgroup_opt(zi)
    if s_name in keys(opt_group.groups)
        opt_group.groups[s_name].arrays
    else
        nothing
    end
end

@doc "Clear all optimization session of a strategy.
`keep_by`: will not delete sessions that match this attributes (`Dict{String, Any}`).
    - `ctx`: the `Context` of the optimization session
    - `params`: the params (`NamedTuple`) of the optimization session
    - `attrs`: the config (`NamedTuple`) of the optimization session
"
function delete_sessions!(s_name::String; keep_by=Dict{String,Any}(), zi=zilmdb())
    delete_all = isempty(keep_by)
    @assert delete_all || all(k ∈ ("ctx", "params", "attrs") for k in keys(keep_by)) "`keep_by` only support ctx, params or attrs keys."
    for z in values(optsessions(s_name; zi))
        delete_all && begin
            delete!(z)
            continue
        end
        let attrs = z.attrs
            for (k, v) in keep_by
                if k ∈ keys(attrs) && v == todata(Vector{UInt8}(attrs[k]))
                    continue
                else
                    delete!(z)
                    break
                end
            end
        end
    end
end

lowerupper(params) = begin
    lower, upper = [], []
    for p in values(params)
        push!(lower, first(p))
        push!(upper, last(p))
    end
    lower, upper
end

delete_sessions!(s::Strategy; kwargs...) = delete_sessions!(string(nameof(s)); kwargs...)
boptimize!(args...; kwargs...) = error("not loaded")

export OptSession

include("bbopt.jl")
include("grid.jl")
