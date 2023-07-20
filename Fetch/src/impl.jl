using Exchanges.Instruments
using Exchanges:
    Exchanges,
    Exchange,
    setexchange!,
    tickers,
    getexchange!,
    issupported,
    save_ohlcv,
    to_float
using Exchanges.Ccxt
using Pbar
using Python
using Python: pylist_to_matrix, py_except_name
using Processing: cleanup_ohlcv_data, islast, resample
using Exchanges.Data:
    Data,
    load,
    to_ohlcv,
    zi,
    PairData,
    DataFrame,
    nrow,
    empty_ohlcv,
    contiguous_ts,
    Candle,
    OHLCV_COLUMNS,
    OHLCVTuple,
    ohlcvtuple
import .Data: propagate_ohlcv!
using .Data.DFUtils: lastdate, colnames, addcols!
using .Data.DataStructures: SortedDict
using .Data.Misc
using .Misc: _instantiate_workers, config, DATA_PATH, fetch_limits, drop, StrOrVec, Iterable
using .Misc.TimeTicks
using .TimeTicks: TimeFrameOrStr, timestamp, dtstamp
using .Misc.Lang: @distributed, @parallel, Option, filterkws, @ifdebug, @deassert
@ifdebug using .TimeTicks: dt

@doc "Used to slide the `since` param forward when retrying fetching (in case the requested timestamp is too old)."
const SINCE_MIN_PERIOD = Millisecond(Day(30))

function pytofloat(v::Py, def=zero(DFT))::DFT
    if pyisinstance(v, pybuiltins.float)
        pyconvert(DFT, v)
    elseif pyisinstance(v, pybuiltins.str)
        isempty(v) ? zero(DFT) : pyconvert(DFT, pyfloat(v))
    else
        def
    end
end

function _to_candle(py, idx, range)
    Candle(dt(pyconvert(Float64, py[idx])), (to_float(py[n]) for n in range)...)
end
Base.convert(::Type{Candle}, py::PyList) = _to_candle(py, 1, 2:6)
Base.convert(::Type{Candle}, py::Py) = _to_candle(py, 0, 1:5)
_pytoval(::Type{DateTime}, v) = dt(to_float(v))
_pytoval(t::Type, v) = @something pyconvert(t, v) Data.default(t)
_pytoval(t::Type, v, def) = @something pyconvert(t, v) def
const OHLCVTupleTypes = (DateTime, fill(Float64, 4)..., Option{Float64})
# const OHLCVTupleTypes = (DateTime, (Float64 for _ in 1:4)..., Option{Float64})
@doc "This is the fastest (afaik) way to convert ccxt lists to dataframe friendly format."
function Base.convert(::Type{OHLCVTuple}, py::Py)
    vecs = ohlcvtuple()
    loopcols((c, v)) = push!(vecs[c], _pytoval(OHLCVTupleTypes[c], v))
    looprows(cdl) = foreach(loopcols, enumerate(cdl))
    foreach(looprows, py)
    vecs
end
_to_ohlcv_vecs(v)::OHLCVTuple = convert(OHLCVTuple, v)
Data.to_ohlcv(py::Py) = DataFrame(_to_ohlcv_vecs(py), OHLCV_COLUMNS)

function _check_from_to(from::F, to::T) where {F,T<:DateType}
    from = timefloat(from)
    if to === ""
        to = timefloat(now())
    else
        to = timefloat(to)
        from > to &&
            error("End date ($(to |> dt)) must be higher than start date ($(from |> dt)).")
    end
    (from, to)
end

@doc "Ensure a `to` date is set, before fetching."
function _fetch_ohlcv_from_to(
    exc::Exchange,
    pair,
    timeframe;
    from="",
    to="",
    params=PyDict(),
    sleep_t=1,
    cleanup=true,
    out=empty_ohlcv(),
    ohlcv_kind=:default,
)
    (from, to) = _check_from_to(from, to)
    @debug "Fetching $ohlcv_kind ohlcv for $pair from $(exc.name) at $timeframe - from: $(from |> dt) - to: $(to |> dt)."
    py_fetch_func = getproperty(exc, ohlcv_func_bykind(ohlcv_kind))
    function fetch_func(pair, since, limit; usetimeframe=true)
        kwargs = LittleDict()
        isnothing(since) || (kwargs[:since] = since)
        isnothing(limit) || (kwargs[:limit] = limit)
        usetimeframe && (kwargs[:timeframe] = timeframe)
        isempty(params) || (kwargs[:params] = params)
        pyfetch(py_fetch_func, pair; kwargs...)
    end
    limit = fetch_limit(exc, nothing)
    data = _fetch_loop(fetch_func, exc, pair; from, to, sleep_t, limit, out)
    cleanup ? cleanup_ohlcv_data(data, timeframe) : data
end

function __ordered_timeframes(exc)
    tfs = collect(exc.timeframes)
    periods = period.(convert.(TimeFrame, tfs))
    order = sortperm(periods; rev=true)
    periods = @view periods[order]
    tfs = @view tfs[order]
    tfs, periods
end

function _since_timestamp(actual::DateTime, p::Period)
    date = max(actual - Year(20), actual - 1000 * Millisecond(p))
    dtstamp(date, Val(:round))
end

@doc "Should return the oldest possible timestamp for a pair, or something close to it."
function find_since(exc::Exchange, pair)
    data = ()
    actual = now()
    tfs, periods = __ordered_timeframes(exc)
    for (t, p) in zip(tfs, periods)
        since_ts = _since_timestamp(actual, p)
        # fetch the first available candles using a long (1w) timeframe
        data = _fetch_ohlcv_with_delay(
            exc, pair; timeframe=t, since=since_ts, df=true, retry=false
        )
        !isempty(data) && break
    end
    if isempty(data)
        # try without `since` arg
        data = _fetch_ohlcv_with_delay(exc, pair; timeframe=tfs[begin], df=true)
    end
    # default to 1 day
    dtstamp(isempty(data) ? now() - Day(1) : data[begin, 1], Val(:round))
end

function fetch_limit(exc::Exchange, limit::Option{Int})
    if isnothing(limit)
        get(fetch_limits, Symbol(lowercase(string(exc.name))), 1000)
    end
end

function __get_since(exc, fetch_func, pair, limit, from, out, is_df, converter)
    if from == 0.0
        find_since(exc, pair)
    else
        append!(
            out,
            _fetch_with_delay(
                fetch_func, pair; since=Int(from), df=is_df, limit, converter
            ),
        )
        if size(out, 1) > 0
            Int(timefloat(out[end, 1]))
        else
            @debug "Couldn't fetch data for $pair from $(exc.name), too long dates? $(dt(from))."
            s = find_since(exc, pair)
            s
        end
    end
end

@doc "Calls the fetc_func iteratively until the full dates range has been downloaded.
NOTE: The returned data won't be exactly the number of candles expected by e.g. `length(DateRange(from, to))`"
function _fetch_loop(
    fetch_func::Function,
    exc::Exchange,
    pair;
    from::F,
    to::F,
    sleep_t,
    out=empty_ohlcv(),
    converter::Function=_to_ohlcv_vecs,
    limit=nothing,
) where {F<:AbstractFloat}
    @debug "Downloading data for pair $pair."
    last_fetched_count = Ref(0)
    pair ∉ keys(exc.markets) && throw("Pair $pair not in exchange markets.")
    is_df = out isa DataFrame
    since = __get_since(exc, fetch_func, pair, limit, from, out, is_df, converter)
    since = since_param(exc, since)
    @debug "since time: ", since
    @debug "Starting from $(dt(since)) - to: $(dt(to))."
    function dofetch()
        sleep(sleep_t)
        fetched = _fetch_with_delay(fetch_func, pair; since, df=is_df, limit, converter)
        last_fetched_count[] = size(fetched, 1)
        size(fetched, 1) == 0 ? false : (append!(out, fetched); true)
    end
    lastts(out) = Int(timefloat(out[end, 1]))
    if isnothing(since)
        dofetch()
    else
        while since < to
            dofetch() || break
            last_ts = lastts(out)
            since == last_ts && break
            since = last_ts
            @debug "Downloaded data for pair $pair up to $(since |> dt) ($(last_fetched_count[]) of $limit) from $(exc.name)."
        end
    end
    return out
end

macro return_empty()
    :(return $(esc(:df)) ? empty_ohlcv() : [])
end

function __handle_error(e, fetch_func, pair, since, df, sleep_t, limit, converter, retry)
    !retry && @return_empty()
    if e isa TaskFailedException
        e = e.task.result
    end
    if e isa PyException
        if !isnothing(match(r"429([0]+)?", string(e._v)))
            @debug "Exchange error 429, too many requests."
            sleep(sleep_t)
            sleep_t = (sleep_t + 1) * 2
            limit = isnothing(limit) ? limit : limit ÷ 2
            _fetch_with_delay(
                fetch_func,
                pair;
                since,
                df,
                sleep_t,
                limit,
                converter,
                usetimeframe=limit > 500,
            )
        elseif py_except_name(e) ∈ ccxt_errors
            @warn "Error downloading ohlc data for pair $pair on exchange $(exc.name). \n $(e._v)"
            @return_empty()
        else
            rethrow(e)
        end
    elseif e isa InterruptException
        @return_empty()
    else
        rethrow(e)
    end
end

function __handle_fetch(
    fetch_func, pair, since, limit, sleep_t, df, converter, retry, usetimeframe
)
    @debug "Calling into ccxt to fetch data: $pair since $(dt(since)), max: $limit, tf: $usetimeframe"
    data = fetch_func(pair, since, limit; usetimeframe)
    dpl = pyisinstance(data, @py(list))
    if retry && (!dpl || length(data) == 0)
        @debug "Downloaded data is not a matrix...retrying (since: $(dt(since)))."
        sleep(sleep_t)
        since_arg = if isnothing(since)
            ()
        else
            tmp = round(Int, since * 1.005)
            if tmp > dtstamp(now())
                limit = fetch_limit(exc, nothing)
                ()
            else
                (; since=tmp)
            end
        end
        # sleep_t = (sleep_t + 1) * 2
        return (
            true,
            _fetch_with_delay(
                fetch_func,
                pair;
                since_arg...,
                df,
                sleep_t,
                limit=max(10, something(limit, 20) ÷ 2),
                converter,
                retry=limit > 10,
                usetimeframe=limit > 500,
            ),
        )
    end
    (false, data)
end

@doc """
Wraps a fetching function around error handling and backoff delay.
`fetch_func` signature:
(pair::String, since::Option{Float}, limit::Float) -> PyList
The `converter` function has to tabulate the data such that the first column is the timestamp
"""
function _fetch_with_delay(
    fetch_func::Function,
    pair;
    since=nothing,
    df=false,
    sleep_t=0,
    limit=nothing,
    converter=_to_ohlcv_vecs,
    retry=true,
    usetimeframe=true,
)
    try
        handled, data = __handle_fetch(
            fetch_func, pair, since, limit, sleep_t, df, converter, retry, usetimeframe
        )
        handled && return data
        # Apply conversion to fetched data
        data::Union{Py,OHLCVTuple,<:AbstractArray,DataFrame} = converter(data)
        handle_empty(data) = df ? empty_ohlcv() : data
        handle_empty(data::DataFrame) = data
        handle_data(data) = df ? to_ohlcv(data) : data
        handle_data(data::DataFrame) = data
        isempty(data) || size(data, 1) == 0 ? handle_empty(data) : handle_data(data)
    catch e
        __handle_error(e, fetch_func, pair, since, df, sleep_t, limit, converter, retry)
    end
end

function ohlcv_func_bykind(kind)
    if kind == :mark
        :fetchMarkOHLCV
    elseif kind == :index
        :fetchIndexOHLCV
    elseif kind == :premium
        :fetchPremiumIndexOHLCV
    else
        :fetchOHLCV
    end
end

function _fetch_ohlcv_with_delay(exc::Exchange, args...; ohlcv_kind=:default, kwargs...)
    limit = get(kwargs, :limit, nothing)
    limit = fetch_limit(exc, limit)
    timeframe = get(kwargs, :timeframe, config.min_timeframe)
    params = get(kwargs, :params, PyDict())
    py_fetch_func = getproperty(exc, ohlcv_func_bykind(ohlcv_kind))
    function fetch_func(pair, since, limit; usetimeframe=true)
        kwargs = LittleDict()
        isnothing(since) || (kwargs[:since] = since)
        isnothing(limit) || (kwargs[:limit] = limit)
        usetimeframe && (kwargs[:timeframe] = timeframe)
        isempty(params) || (kwargs[:params] = params)
        pyfetch(py_fetch_func, pair; kwargs...)
    end
    kwargs = collect(filterkws(:params, :timeframe, :limit; kwargs, pred=∉))
    _fetch_with_delay(fetch_func, args...; limit, kwargs...)
end
# FIXME: we assume the exchange class is set (is not pynull), if itsn't set PythonCall segfaults
function fetch_ohlcv(exc, timeframe, pairs; kwargs...)
    pairs = pairs isa String ? [pairs] : pairs
    fetch_ohlcv(exc, string(timeframe), pairs; kwargs...)
end
function fetch_ohlcv(exc, timeframe; qc=config.qc, kwargs...)
    pairs = tickers(exc, qc; as_vec=true)
    fetch_ohlcv(exc, string(timeframe), pairs; kwargs...)
end

function fetch_ohlcv(::Val{:ask}, args...; kwargs...)
    Base.display("fetch? Y/n")
    ans = String(read(stdin, 1))
    ans ∉ ("\n", "y", "Y") && return nothing
    fetch_ohlcv(args...; qc=config.qc, zi, kwargs...)
end

@doc """ Fetch ohlcv data for multiple exchanges on the same timeframe.

It accepts:
- a mapping of exchange instances to pairlists.
- a vector of symbols for which an exchange instance will be instantiated for each element,
    and pairlist will be composed according to quote currency and min_volume from `PingPong.config`.
"""
function fetch_ohlcv(
    excs::Vector{Exchange}, timeframe; parallel=false, wait_task=false, kwargs...
)
    # out_file = joinpath(DATA_PATH, "out.log")
    # err_file = joinpath(DATA_PATH, "err.log")
    # FIXME: find out how io redirection interacts with distributed
    # t = redirect_stdio(; stdout=out_file, stderr=err_file) do
    parallel && _instantiate_workers(:PingPong; num=length(excs))
    # NOTE: The python classes have to be instantiated inside the worker processes
    if eltype(excs) === Symbol
        e_pl = s -> (ex = getexchange!(s); (ex, tickers(ex; as_vec=true)))
    else
        e_pl = s -> (getexchange!(Symbol(lowercase(s[1].name))), s[2])
    end
    t = @parallel parallel for s in excs
        ex, pl = e_pl(s)
        fetch_ohlcv(ex, timeframe, pl; kwargs...)
    end
    # end
    parallel && wait_task && wait(t)
    t
end

function __ensure_dates(exc, tf, from, to)
    if !issupported(string(tf), exc)
        error("Timeframe $tf not supported by exchange $(exc.name).")
    end
    from_to_dt(tf, from, to)
end

function __from_date_func(update, timeframe, from, to, zi, exc_name, reset)
    if update
        if !isempty(string(from)) || !isempty(string(to))
            @warn "Don't set the `from` or `to` date if updating existing data."
        end
        reset && @warn "Ignoring reset since, update flag is true."
        # this fetches the last date stored
        from_date =
            (pair) -> begin
                za, (_, stop) = load(zi, exc_name, pair, timeframe; as_z=true)
                za, size(za, 1) > 1 ? za[stop, 1] : from
            end
    else
        from_date = Returns((nothing, from))
    end
end
__print_progress_1(pairs) = begin
    @info "Downloading data for $(length(pairs)) pairs."
    @pbar! pairs "Pairlist download progress" "pair"
    pb_job
end
function __get_ohlcv(
    exc,
    name,
    timeframe,
    from_date,
    to;
    out=empty_ohlcv(),
    cleanup=true,
    ohlcv_kind=:default,
)
    @debug "Fetching pair $name."
    z, pair_from_date = from_date(name)
    @debug "...from date $(pair_from_date)"
    this_date = if pair_from_date isa DateTime
        pair_from_date
    else
        @something tryparse(DateTime, pair_from_date) DateTime(0)
    end
    if !islast(this_date, timeframe)
        ohlcv = _fetch_ohlcv_from_to(
            exc, name, timeframe; from=pair_from_date, to, cleanup, out, ohlcv_kind
        )
    else
        ohlcv = empty_ohlcv()
    end
    ohlcv, z
end
function __handle_save_ohlcv_error(::ContiguityException, exc_name, name, timeframe, ohlcv)
    save_ohlcv(zi, exc_name, name, timeframe, ohlcv; reset=true)
end
function __handle_save_ohlcv_error(e::AssertionError, _, name, args...)
    @error "Could not fetch data for pair $name, check integrity of saved data." err = e
end
function __handle_save_ohlcv_error(e, args...)
    rethrow(e)
end
function __save_ohlcv(zi, ohlcv, name, timeframe, exc_name, reset)
    try
        save_ohlcv(zi, exc_name, name, timeframe, ohlcv; reset)
    catch e
        __handle_save_ohlcv_error(e, exc_name, name, timeframe, ohlcv)
    end
end
function __pairdata!(zi, data, ohlcv, name, timeframe, z, exc_name, reset)
    z = if size(ohlcv, 1) > 0
        __save_ohlcv(zi, ohlcv, name, timeframe, exc_name, reset)
    elseif isnothing(z)
        load(zi, exc_name, name, timeframe; as_z=true)[1]
    else
        z
    end
    p = PairData(; name, tf=timeframe, data=ohlcv, z)
    @debug "Fetched $(size(p.data, 1)) candles for $name from $(exc_name)"
    data[name] = p
end

using .Data: ZarrInstance, ZArray
@doc """Fetch ohlcv data from exchange for a list of pairs.
- `from`, `to`: Can represent a date. A negative `from` number implies fetching the last N=`from` candles.
- `update`: If true, will check for cached data, and fetch only missing candles. (`false`)
- `progress`: if true, show a progress bar. (`true`)
- `reset`: if true, will remove cached data before fetching. (`false`)
"""
function fetch_ohlcv(
    exc::Exchange,
    timeframe::AbstractString,
    pairs::Iterable;
    zi=zi[],
    from::DateType="",
    to::DateType="",
    update=false,
    reset=false,
    progress=false,
    ohlcv_kind=:default,
)
    local pb_job = nothing
    @assert !isempty(exc) "Bad exchange."
    exc_name = exc.name
    from, to = __ensure_dates(exc, timeframe, from, to)
    from_date = __from_date_func(update, timeframe, from, to, zi, exc_name, reset)
    data::Dict{String,PairData} = Dict{String,PairData}()
    progress && (pb_job = __print_progress_1(pairs))
    function data!(name)
        ohlcv, z = __get_ohlcv(exc, name, timeframe, from_date, to; ohlcv_kind)
        __pairdata!(zi, data, ohlcv, name, timeframe, z, exc_name, reset)
        progress && @pbupdate!
    end
    try
        foreach(data!, pairs)
    finally
        progress && @pbstop!
    end
    data
end

@doc "Updates the tail of an ohlcv dataframe with the most recent candles."
function update_ohlcv!(df::DataFrame, pair, exc, tf; ohlcv_kind=:default)
    from = if isempty(df)
        DateTime(0)
    else
        iscontig, idx, last_date = contiguous_ts(
            df.timestamp, string(tf); raise=false, return_date=true
        )
        if !iscontig
            deleteat!(df, idx:lastindex(df.timestamp))
        end
        @deassert dt(last_date) == lastdate(df) dt(last_date), lastdate(df)
        last_date
    end
    if !islast(dt(from), tf)
        cleaned = _fetch_ohlcv_from_to(
            exc, pair, string(tf); from, to=now(), cleanup=true, ohlcv_kind
        )
        Data.DFUtils.addcols!(cleaned, df)
        empty!(df)
        append!(df, cleaned)
    end
    df
end

function propagate_ohlcv!(data::SortedDict, pair::AbstractString, exc::Exchange)
    function doupdate!(base_tf, base_data, tf, tf_data)
        let res = resample(base_data, base_tf, tf)
            addcols!(res, tf_data)
            append!(tf_data, res)
        end
        let tmp = cleanup_ohlcv_data(tf_data, tf)
            addcols!(tmp, tf_data)
            empty!(tf_data)
            append!(tf_data, tmp)
        end
        update_ohlcv!(tf_data, pair, exc, tf)
    end
    propagate_ohlcv!(data, doupdate!)
end

function _fetch_candles(
    exc, timeframe, pairs::Iterable; from::D1, to::D2, ohlcv_kind=:default
) where {D1,D2<:Union{DateTime,AbstractString}}
    @sync Dict(
        name => @async __get_ohlcv(
            exc,
            name,
            timeframe,
            Returns((nothing, from)),
            to;
            cleanup=false,
            ohlcv_kind,
        )[1] for name in pairs
    )
end

function _fetch_candles(
    exc, timeframe, pair::AbstractString; from::D1, to::D2, ohlcv_kind=:default
) where {D1,D2<:Union{DateTime,AbstractString}}
    __get_ohlcv(
        exc, pair, timeframe, Returns((nothing, from)), to; cleanup=false, ohlcv_kind
    )[1]
end

function fetch_candles(
    exc::Exchange,
    timeframe::AbstractString,
    pairs::Union{AbstractString,Iterable};
    from::Option{DateType}="",
    to::DateType="",
    ohlcv_kind=:default,
)
    from, to = __ensure_dates(exc, timeframe, something(from, ""), to)
    _fetch_candles(exc, timeframe, pairs; from, to, ohlcv_kind)
end

function fetch_candles(exc::Exchange, tf::TimeFrame, args...; kwargs...)
    fetch_candles(exc, string(tf), args...; kwargs...)
end

export fetch_ohlcv, fetch_candles
