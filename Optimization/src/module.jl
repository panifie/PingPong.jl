using SimMode: SimMode
using SimMode.Executors: st, Instances, OptSetup, OptRun, OptScore, Context
using SimMode.TimeTicks
using .Instances: value
using .Instances.Data: DataFrame, Not, save_data, load_data, nrow, todata, tobytes
using .Instances.Data: zinstance, Zarr as za
using .Instances.Data.Zarr: getattrs, writeattrs
using .Instances.Exchanges: exc, sb_exchanges
using .st: Strategy, Sim, SimStrategy, WarmupPeriod
using SimMode.Misc: DFT
using SimMode.Lang: Option, splitkws, @debug_backtrace
using Stats.Statistics: median, mean
using Stats: Stats
using REPL.TerminalMenus
using Pkg: Pkg
using Base.Threads: threadid
using SimMode.Misc.DocStringExtensions
import .st: ping!

include("utils.jl")

@doc "A named tuple representing the context and space in the optimization process."
const ContextSpace = NamedTuple{(:ctx, :space),Tuple{Context,Any}}
@doc """ A mutable structure representing the running state of an optimization process.

$(FIELDS)

This structure contains a single field `value` which is an atomic boolean.
It is used to indicate whether the optimization process is currently running or not.
"""
mutable struct OptRunning
    @atomic value::Bool
end
@doc "A constant instance of `OptRunning` initialized with `false`."
const RUNNING = OptRunning(false)
@doc """ Sets the running state of the optimization process to `true`.

$(TYPEDSIGNATURES)

This function changes the `value` field of the `RUNNING` instance to `true`, indicating that the optimization process is currently running.
"""
running!() = @atomic RUNNING.value = true
@doc """ Sets the running state of the optimization process to `false`.

$(TYPEDSIGNATURES)

This function changes the `value` field of the `RUNNING` instance to `false`, indicating that the optimization process is not currently running.
"""
stopping!() = @atomic RUNNING.value = false
@doc """ Checks if the optimization process is currently running.

$(TYPEDSIGNATURES)

This function returns the `value` field of the `RUNNING` instance, indicating whether the optimization process is currently running.
"""
isrunning() = @atomic RUNNING.value

@doc """ Returns `Optimizations.ContextSpace` for backtesting

$(TYPEDSIGNATURES)

The `ctx` field (`Executors.Context`) specifies the backtest time period, while `space` is either an already built `BlackBoxOptim.SearchSpace` subtype or a tuple (`Symbol`, args...) for a pre-defined BBO package search space.
"""
ping!(::Strategy, ::OptSetup)::ContextSpace = error("not implemented")

@doc """ Applies parameters to strategy before backtest

$(TYPEDSIGNATURES)
"""
ping!(::Strategy, params, ::OptRun) = error("not implemented")

@doc """ A structure representing an optimization session.

$(FIELDS)

This structure stores all the evaluated parameters combinations during an optimization session.
It contains fields for the strategy, context, parameters, attributes, results, best result, lock, and clones of the strategy and context for each thread.
The constructor for `OptSession` also takes an offset and number of threads as optional parameters, with default values of 0 and the number of available threads, respectively.
"""
struct OptSession{S<:SimStrategy,N}
    s::S
    ctx::Context{Sim}
    params::T where {T<:NamedTuple}
    attrs::Dict{Symbol,Any}
    results::DataFrame
    best::Ref{Any}
    lock::ReentrantLock
    s_clones::NTuple{N,Tuple{ReentrantLock,S}}
    ctx_clones::NTuple{N,Context{Sim}}
    function OptSession(
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
@doc """ Generates a unique key for an optimization session.

$(TYPEDSIGNATURES)

This function generates a unique key for an optimization session by combining various parts of the session's properties.
The key is a combination of the session's strategy name, context range, parameters, and a hash of the parameters and attributes.
"""
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

@doc "Get the `Opt` group from the provided zarr instance."
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
@doc """ Returns the zarr group for a given strategy.

$(TYPEDSIGNATURES)

This function checks if a zarr group exists for the given strategy name in the optimization group of the zarr instance.
If it exists, the function returns the group; otherwise, it creates a new zarr group for the strategy.
"""
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

@doc """ Save the optimization session over the provided zarr instance

$(TYPEDSIGNATURES)

`sess` is the `OptSession` to be saved. The `from` parameter specifies the starting index for saving optimization results progressively, while `to` specifies the ending index. The function uses the provided zarr instance `zi` for storage.
The function first ensures that the zgroup for the strategy exists. Then, it writes various session attributes to zarr if we're starting from the beginning (`from == 0`). Finally, it saves the result data for the specified range (`from` to `to`).

"""
function save_session(sess::OptSession; from=0, to=nrow(sess.results), zi=zinstance())
    k, parts = session_key(sess)
    # ensure zgroup
    zgroup_strategy(zi, sess.s)
    save_data(
        zi,
        k,
        [(DateTime(from), @view(sess.results[max(1, from):to, :]))];
        chunk_size=(256, 2),
        serialize=true,
    )
    # NOTE: set attributes *after* saving otherwise they do not persist
    if from == 0
        z = load_data(zi, k; serialized=true, as_z=true)[1]
        attrs = z.attrs
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

@doc """ Generates a regular expression for matching optimization session keys.

$(TYPEDSIGNATURES)

The function takes three arguments: `startstop`, `params_k`, and `code`.
These represent the start and stop date of the backtesting context, the first letter of every parameter, and a hash of the parameters and attributes truncated to 4 characters, respectively.
The function returns a `Regex` object that matches the string representation of an optimization session key.
"""
function rgx_key(startstop, params_k, code)
    Regex("$startstop:$params_k$code")
end

function _anyexc()
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
@doc """ Loads an optimization session from storage.

$(TYPEDSIGNATURES)

This function loads an optimization session from the provided zarr instance `zi` based on the given parameters.
The parameters include the strategy name, start and stop date of the backtesting context, the first letter of every parameter, and a hash of the parameters and attributes truncated to 4 characters.
The function returns the loaded session, either as a zarr array if `as_z` is `true`, or as an `OptSession` object otherwise.
If `results_only` is `true`, only the results DataFrame of the session is returned.
"""
function load_session(
    name,
    startstop=".*",
    params_k=".*",
    code="";
    zi=zinstance(),
    as_z=false,
    results_only=false,
    s=nothing,
)
    load(k) = begin
        load_data(zi, k; serialized=true, as_z=true)[1]
    end
    function results!(df, z)
        try
            for row in eachrow(z)
                append!(df, todata(row[2]))
            end
        catch
            @debug_backtrace
        end
        df
    end
    function ensure_attrs(z, retry_f, remove_broken=nothing)
        attrs = z.attrs
        if isempty(attrs)
            @error "ZArray should contain session attributes."
            if isnothing(remove_broken) &&
                isinteractive() &&
                Base.prompt("delete entry $(z.path)? [y]/n") == "n"
                remove_broken = false
            else
                remove_broken = true
                delete!(z)
            end
            if retry_f isa Function
                z = ensure_attrs(retry_f(), retry_f, remove_broken)
            end
        end
        z
    end

    function session(z, retry_f)
        as_z && return z
        results_only && return results!(DataFrame(), z)
        sess = let z = ensure_attrs(z, retry_f)
            attrs = z.attrs
            OptSession(
                @something s st.strategy(
                    Symbol(attrs["name"]); exchange=_anyexc(), mode=Sim()
                );
                ctx=_deserattrs(attrs, "ctx"),
                params=_deserattrs(attrs, "params"),
                attrs=_deserattrs(attrs, "attrs"),
            )
        end
        results!(sess.results, z)
        return sess
    end
    retry_f = nothing
    z = if all((x -> x != ".*").((name, startstop, params_k, code)))
        k = "Opt/$name/$startstop:$params_k$code"
        z = load(k)
    else
        rgx = rgx_key(startstop, params_k, code)
        root = zgroup_opt(zi)
        all_arrs = if haskey(root.groups, name)
            root.groups[name].arrays
        else
            root.arrays
        end
        arrs = filter(pair -> occursin(rgx, pair.first), all_arrs)
        if length(arrs) == 0
            parts = ((k for k in (name, startstop, params_k, code) if k != ".*")...,)
            throw(KeyError(parts))
        elseif length(arrs) == 1
            v = first(arrs)
            v.second
        else
            picks = string.(keys(arrs))
            pick_arr() = begin
                display("Select the session key: ")
                picked = request(RadioMenu(picks; pagesize=4))
                k = picks[picked]
                filter!(x -> x != k, picks)
                get(arrs, k, nothing)
            end
            retry_f = pick_arr
            pick_arr()
        end
    end
    return session(z, retry_f)
end

function load_session(sess::OptSession, args...; kwargs...)
    load_session(values(session_key(sess)[2])..., args...; sess.s, kwargs...)
end

function load_session(s::Strategy)
    load_session(string(nameof(s)); s)
end

@doc """ Calculates the small and big steps for the optimization context.

$(TYPEDSIGNATURES)

The function takes two arguments: `ctx` and `splits`.
`ctx` is the optimization context and `splits` is the number of splits for the optimization process.
The function returns a named tuple with `small_step` and `big_step` which represent the step size for the optimization process.
"""
function ctxsteps(ctx, splits)
    small_step = Millisecond(ctx.range.step).value
    big_step = let timespan = Millisecond(ctx.range.stop - ctx.range.start).value
        Millisecond(round(Int, timespan / max(1, splits - 1)))
    end
    (; small_step, big_step)
end

@doc """ Calculates the metrics for a given strategy.

$(TYPEDSIGNATURES)

The function takes a strategy `s` and an initial cash amount as arguments.
It calculates the objective score, the current total cash, the profit and loss ratio, and the number of trades.
The function returns these metrics as a named tuple.
"""
metrics_func(s; initial_cash) = begin
    obj = ping!(s, OptScore())
    # record run
    cash = value(st.current_total(s))
    pnl = cash / initial_cash - 1.0
    trades = st.trades_count(s)
    (; obj, cash, pnl, trades)
end

@doc """ Defines the backtest function for an optimization session.

$(TYPEDSIGNATURES)

The function takes three arguments: `sess`, `small_step`, and `big_step`.
`sess` is the optimization session, `small_step` is the small step size for the optimization process, and `big_step` is the big step size for the optimization process.
The function returns a function that performs a backtest for a given set of parameters and a given iteration number.
"""
function define_backtest_func(sess, small_step, big_step)
    function opt_backtest_func(params, n)
        tid = Threads.threadid()
        slot = sess.s_clones[tid]
        @lock slot[1] begin
            # `ofs` is used as custom input source of randomness
            s = slot[2]
            ctx = sess.ctx_clones[tid]
            ofs = sess.attrs[:offset] + n
            # clear strat
            st.reset!(s, true)
            # set params as strategy attributes
            setparams!(s, sess, params)
            # Pre backtest hook
            ping!(s, params, OptRun())
            # randomize strategy startup time
            let wp = ping!(s, WarmupPeriod()),
                inc = Millisecond(round(Int, small_step / ofs)) + big_step * (n - 1)

                current!(ctx.range, ctx.range.start + wp + inc)
            end
            # backtest and score
            initial_cash = value(s.cash)
            start!(s, ctx; doreset=false, resetctx=false)
            st.sizehint!(s) # avoid deallocations
            metrics = metrics_func(s; initial_cash)
            lock(sess.lock) do
                push!(
                    sess.results,
                    (;
                        repeat=ofs,
                        metrics...,
                        (pname => p for (pname, p) in zip(keys(sess.params), params))...,
                    ),
                )
            end
            metrics.obj
        end
    end
end

@doc """ Multi-threaded optimization function.

$(TYPEDSIGNATURES)

The function takes four arguments: `splits`, `backtest_func`, `median_func`, and `obj_type`.
`splits` is the number of splits for the optimization process, `backtest_func` is the backtest function, `median_func` is the function to calculate the median, and `obj_type` is the type of the objective.
The function returns a function that performs a multi-threaded optimization for a given set of parameters.
"""
function _multi_opt_func(splits, backtest_func, median_func, obj_type)
    (params) -> begin
        job(n) = backtest_func(params, n)
        scores = Vector{obj_type}(undef, splits)
        Threads.@threads for n in 1:splits
            if isrunning()
                scores[n] = job(n)
            end
        end

        mapreduce(permutedims, vcat, scores) |> median_func
    end
end

@doc """ Single-threaded optimization function.

$(TYPEDSIGNATURES)

The function takes four arguments: `splits`, `backtest_func`, `median_func`, and `obj_type`.
`splits` is the number of splits for the optimization process, `backtest_func` is the backtest function, `median_func` is the function to calculate the median, and `obj_type` is the type of the objective.
The function returns a function that performs a single-threaded optimization for a given set of parameters.
"""
function _single_opt_func(splits, backtest_func, median_func, args...)
    (params) -> begin
        mapreduce(permutedims, vcat, [(backtest_func(params, n) for n in 1:splits)...]) |> median_func
    end
end

@doc """ Defines the median function for multi-objective mode.

$(TYPEDSIGNATURES)

The function takes a boolean argument `ismulti` which indicates if the optimization is multi-objective.
If `ismulti` is `true`, the function returns a function that calculates the median over all the repeated iterations.
Otherwise, it returns a function that calculates the median of a given array.
"""
function define_median_func(ismulti)
    if ismulti
        (x) -> tuple(median(x; dims=1)...)
    else
        (x) -> median(x)
    end
end

@doc """ Defines the optimization function for a given strategy.

$(TYPEDSIGNATURES)

The function takes several arguments: `s`, `backtest_func`, `ismulti`, `splits`, `obj_type`, and `isthreaded`.
`s` is the strategy, `backtest_func` is the backtest function, `ismulti` indicates if the optimization is multi-objective, `splits` is the number of splits for the optimization process, `obj_type` is the type of the objective, and `isthreaded` indicates if the optimization is threaded.
The function returns the appropriate optimization function based on these parameters.
"""
function define_opt_func(
    s::Strategy; backtest_func, ismulti, splits, obj_type, isthreaded=isthreadsafe(s)
)
    median_func = define_median_func(ismulti)
    opt_func = isthreaded ? _multi_opt_func : _single_opt_func
    opt_func(splits, backtest_func, median_func, obj_type)
end

@doc """ Returns the number of objectives and their type.

$(TYPEDSIGNATURES)

The function takes a strategy `s` as an argument.
It returns a tuple containing the type of the objective and the number of objectives.
"""
function objectives(s)
    let test_obj = ping!(s, OptScore())
        typeof(test_obj), length(test_obj)
    end
end

@doc """ Fetches the named tuple of a single parameters combination.

$(TYPEDSIGNATURES)

The function takes an optimization session `sess` and an optional index `idx` (defaulting to the last row of the results).
It returns the parameters of the optimization session at the specified index as a named tuple.
"""
function result_params(sess::OptSession, idx=nrow(sess.results))
    iszero(idx) && return nothing
    row = sess.results[idx, :]
    (; (k => getproperty(row, k) for k in keys(sess.params))...)
end

@doc """ Generates the path for the log file of a given strategy.

$(TYPEDSIGNATURES)

The function takes a strategy `s` and an optional `name` (defaulting to the current timestamp).
It constructs a directory path based on the strategy's path, and ensures this directory exists.
Then, it returns the full path to the log file within this directory, along with the directory path itself.

"""
function log_path(s, name=split(string(now()), ".")[1])
    dirpath = joinpath(realpath(dirname(s.path)), "logs", "opt", string(nameof(s)))
    isdir(dirpath) || mkpath(dirpath)
    joinpath(dirpath, name * ".log"), dirpath
end

@doc """ Returns the paths to all log files for a given strategy.

$(TYPEDSIGNATURES)

The function takes a strategy `s` as an argument.
It retrieves the directory path for the strategy's log files and returns the full paths to all log files within this directory.

"""
function logs(s)
    dirpath = log_path(s, "")[2]
    joinpath.(dirpath, readdir(dirpath))
end

@doc """ Clears all log files for a given strategy.

$(TYPEDSIGNATURES)

The function takes a strategy `s` as an argument.
It retrieves the directory path for the strategy's log files and removes all files within this directory.

"""
function logs_clear(s)
    dirpath = log_path(s, "")[2]
    for f in readdir(dirpath)
        rm(joinpath(dirpath, f); force=true)
    end
end

@doc """ Prints the content of a specific log file for a given strategy.

$(TYPEDSIGNATURES)

The function takes a strategy `s` and an optional index `idx` (defaulting to the last log file).
It retrieves the directory path for the strategy's log files, selects the log file at the specified index, and prints its content.

"""
function print_log(s, idx=nothing)
    let logs = logs(s)
        isempty(logs) && error("no logs found for strategy $(nameof(s))")
        println(read(logs[@something idx lastindex(logs)], String))
    end
end

maybereduce(v::AbstractVector, f::Function) = f(v)
maybereduce(v, _) = v
function agg(f, sess::OptSession)
    res = sess.results
    if isempty(res)
        res
    else
        gd = groupby(res, [keys(sess.params)...])
        combine(gd, f; renamecols=false)
    end
end
@doc """ Aggregates the results of an optimization session.

$(TYPEDSIGNATURES)

The function takes an optimization session `sess` and optional functions `reduce_func` and `agg_func`.
It groups the results by the session parameters, applies the `reduce_func` to each group, and then applies the `agg_func` to the reduced results.

"""
function agg(sess::OptSession; reduce_func=mean, agg_func=median)
    agg(
        (
            Not([keys(sess.params)..., :repeat]) .=>
                x -> maybereduce(x, reduce_func) |> agg_func
        ),
        sess,
    )
end

function optsessions(s::Strategy; zi=zinstance())
    optsessions(string(nameof(s)); zi)
end

@doc """ Returns the zarrays storing all the optimization session over the specified zarrinstance.

$(TYPEDSIGNATURES)

The function takes a strategy `s` as an argument.
It retrieves the directory path for the strategy's log files and returns the full paths to all log files within this directory.

"""
function optsessions(s_name::String; zi=zinstance())
    opt_group = zgroup_opt(zi)
    if s_name in keys(opt_group.groups)
        opt_group.groups[s_name].arrays
    else
        nothing
    end
end

@doc """ Clears optimization sessions of a strategy.

$(TYPEDSIGNATURES)

The function accepts a strategy name `s_name` and an optional `keep_by` dictionary.
If `keep_by` is provided, sessions matching these attributes (`ctx`, `params`, or `attrs`) are not deleted.
It checks each session, and deletes it if it doesn't match `keep_by` or if `keep_by` is empty.

"""
function delete_sessions!(s_name::String; keep_by=Dict{String,Any}(), zi=zinstance())
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

@doc """ Extracts the lower and upper bounds from a parameters dictionary.

$(TYPEDSIGNATURES)

The function takes a parameters dictionary `params` as an argument.
It returns two arrays, `lower` and `upper`, containing the first and last values of each parameter range in the dictionary, respectively.

"""
lowerupper(params) = begin
    lower, upper = [], []
    for p in values(params)
        push!(lower, first(p))
        push!(upper, last(p))
    end
    lower, upper
end

delete_sessions!(s::Strategy; kwargs...) = delete_sessions!(string(nameof(s)); kwargs...)
@doc """ Loads the BayesianOptimization extension.

The function checks if the BayesianOptimization package is installed in the current environment.
If not, it prompts the user to add it to the main environment.

"""
function extbayes!()
    let prev = Pkg.project().path
        try
            Pkg.activate("Optimization"; io=devnull)
            if isnothing(@eval Main Base.find_package("BayesianOptimization"))
                if Base.prompt(
                    "BayesianOptimization package not found, add it to the main env? y/[n]"
                ) == "y"
                    try
                        Pkg.activate(; io=devnull)
                        Pkg.add("BayesianOptimization")
                    finally
                        Pkg.activate("Optimization"; io=devnull)
                    end
                end
            end
            @eval Main using BayesianOptimization
        finally
            Pkg.activate(prev; io=devnull)
        end
    end
end

export OptSession, extbayes!

include("bbopt.jl")
include("grid.jl")
