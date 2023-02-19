using Data:
    Data,
    load,
    to_ohlcv,
    zi,
    PairData,
    DataFrame,
    empty_ohlcv,
    Candle,
    OHLCV_COLUMNS,
    OHLCVTuple
using Ccxt
using Python
using Python: pylist_to_matrix
using ExchangeTypes: Exchange
using Exchanges:
    setexchange!,
    get_pairlist,
    getexchange!,
    is_timeframe_supported,
    py_except_name,
    save_ohlcv
using TimeTicks
using Lang: @distributed, @parallel, Option
using Misc
using Misc: _instantiate_workers, config, DATA_PATH, ohlcv_limits, drop, StrOrVec, Iterable
using TimeTicks: TimeFrameOrStr, timestamp
using Python
using TimeTicks
@debug using TimeTicks: dt
using Pbar
using Processing: cleanup_ohlcv_data, is_last_complete_candle

@doc "Used to slide the `since` param forward when retrying fetching (in case the requested timestamp is too old)."
const SINCE_INC = Millisecond(Day(30)).value

function _to_candle(py, idx, range)
    Candle(dt(pyconvert(Float64, py[idx])), (pyconvert(Float64, py[n]) for n in range)...)
end
Base.convert(::Type{Candle}, py::PyList) = _to_candle(py, 1, 2:6)
Base.convert(::Type{Candle}, py::Py) = _to_candle(py, 0, 1:5)
@doc "This is the fastest (afaik) way to convert ccxt lists to dataframe friendly format."
function Base.convert(::Type{OHLCVTuple}, py::Py)
    vecs = OHLCVTuple()
    loopcols((c, v)) = push!(vecs[c], pyconvert(eltype(vecs[c]), v))
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
)
    (from, to) = _check_from_to(from, to)
    @debug "Fetching pair $pair from exchange $(exc.name) at $timeframe - from: $(from |> dt) - to: $(to |> dt)."
    fetch_func =
        (pair, since, limit) ->
            pyfetch(exc.py.fetchOHLCV, pair; timeframe, since, limit, params)
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

@doc "Should return the oldest possible timestamp for a pair, or something close to it."
function find_since(exc::Exchange, pair)
    data = ()
    tfs, periods = __ordered_timeframes(exc)
    as_int(v) = Int(timefloat(v))
    for (t, p) in zip(tfs, periods)
        old_ts = as_int(Millisecond(p))
        # fetch the first available candles using a long (1w) timeframe
        data = _fetch_ohlcv_with_delay(exc, pair; timeframe=t, since=old_ts, df=true)
        !isempty(data) && break
    end
    if isempty(data)
        # try without `since` arg
        data = _fetch_ohlcv_with_delay(exc, pair; timeframe=tfs[begin], df=true)
    end
    # default to 1 day
    as_int(isempty(data) ? now() - Day(1) : data[begin, 1])
end

function fetch_limit(exc::Exchange, limit::Option{Int})
    if isnothing(limit)
        get(ohlcv_limits, Symbol(lowercase(string(exc.name))), 1000)
    end
end

function __get_since(fetch_func, pair, limit, from, out, is_df, converter)
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
            find_since(exc, pair)
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
    pair ∉ keys(exc.markets) && throw("Pair $pair not in exchange markets.")
    is_df = out isa DataFrame
    since = __get_since(fetch_func, pair, limit, from, out, is_df, converter)
    @debug "since time: ", since
    @debug "Starting from $(dt(since)) - to: $(dt(to))."
    function dofetch()
        sleep(sleep_t)
        fetched = _fetch_with_delay(fetch_func, pair; since, df=is_df, limit, converter)
        size(fetched, 1) == 0 ? false : (append!(out, fetched); true)
    end
    lastts(out) = Int(timefloat(out[end, 1]))
    while since < to
        dofetch() || break
        last_ts = lastts(out)
        since == last_ts && break
        since = last_ts
        @debug "Downloaded data for pair $pair up to $(since |> dt) from $(exc.name)."
    end
    return out
end

function __handle_error(e, fetch_func, pair, since, df, sleep_t, limit, converter)
    if e isa PyException
        if !isnothing(match(r"429([0]+)?", string(e._v)))
            @debug "Exchange error 429, too many requests."
            sleep(sleep_t)
            sleep_t = (sleep_t + 1) * 2
            limit = isnothing(limit) ? limit : limit ÷ 2
            _fetch_with_delay(fetch_func, pair; since, df, sleep_t, limit, converter)
        elseif py_except_name(e) ∈ ccxt_errors
            @warn "Error downloading ohlc data for pair $pair on exchange $(exc.name). \n $(e._v)"
            return df ? empty_ohlcv() : []
        else
            rethrow(e)
        end
    else
        rethrow(e)
    end
end

function __handle_fetch(fetch_func, pair, since, limit, sleep_t, df, converter)
    @debug "Calling into ccxt to fetch data: $pair since $since, max: $limit"
    data = fetch_func(pair, since, limit)
    dpl = pyisinstance(data, @py(list))
    if !dpl || length(data) == 0
        @debug "Downloaded data is not a matrix...retrying (since: $(dt(since)))."
        sleep(sleep_t)
        sleep_t = (sleep_t + 1) * 2
        return (
            true,
            _fetch_with_delay(
                fetch_func,
                pair;
                since=since + SINCE_INC,
                df,
                sleep_t,
                limit=(limit ÷ 2),
                converter,
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
)
    try
        handled, data = __handle_fetch(
            fetch_func, pair, since, limit, sleep_t, df, converter
        )
        handled && return data
        # Apply conversion to fetched data
        data = converter(data)
        handle_empty(data) = df ? empty_ohlcv() : data
        handle_empty(data::DataFrame) = data
        handle_data(data) = df ? to_ohlcv(data) : data
        handle_data(data::DataFrame) = data
        isempty(data) || size(data, 1) == 0 ? handle_empty(data) : handle_data(data)
    catch e
        __handle_error(e, fetch_func, pair, since, df, sleep_t, limit, converter)
    end
end

function _fetch_ohlcv_with_delay(exc::Exchange, args...; kwargs...)
    limit = get(kwargs, :limit, nothing)
    limit = fetch_limit(exc, limit)
    timeframe = get(kwargs, :timeframe, config.timeframe)
    params = get(kwargs, :params, PyDict())
    function fetch_func(pair, since, limit)
        pyfetch(exc.py.fetchOHLCV, pair; since, limit, timeframe, params)
    end
    kwargs = collect((k, v) for (k, v) in kwargs if k ∉ (:params, :timeframe, :limit))
    _fetch_with_delay(fetch_func, args...; limit, kwargs...)
end
# FIXME: we assume the exchange class is set (is not pynull), if itsn't set PythonCall segfaults
function fetch_ohlcv(exc, timeframe, pairs; kwargs...)
    pairs = pairs isa String ? [pairs] : pairs
    fetch_ohlcv(exc, string(timeframe), pairs; kwargs...)
end
function fetch_ohlcv(exc, timeframe; qc, kwargs...)
    pairs = get_pairlist(exc, qc; as_vec=true)
    fetch_ohlcv(exc, string(timeframe), pairs; kwargs...)
end
function fetch_ohlcv(exc, timeframe; kwargs...)
    qc = :qc ∈ keys(kwargs) ? kwargs[:qc] : config.qc
    pairs = collect(keys(get_pairlist(exc, qc)))
    fetch_ohlcv(string(timeframe), pairs; filter(x -> x[1] !== :qc, kwargs)...)
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
        e_pl = s -> (ex = getexchange!(s); (ex, get_pairlist(ex; as_vec=true)))
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

function __ensure_dates(timeframe, from, to, exc_name)
    if !is_timeframe_supported(timeframe, exc)
        error("Timeframe $timeframe not supported by exchange $exc_name.")
    end
    from_to_dt(timeframe, from, to)
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
    @pbar! pairs "Pairlist download progress" "pair" false
    pb
end
function __print_progress_2(name, exc_name)
    @info "Fetched $(size(p.data, 1)) candles for $name from $(exc_name)"
    @pbupdate!
end
function __get_ohlcv(exc, name, timeframe, from_date, to, out=empty_ohlcv())
    @debug "Fetching pair $name."
    z, pair_from_date = from_date(name)
    @debug "...from date $(pair_from_date)"
    if !is_last_complete_candle(pair_from_date, timeframe)
        ohlcv = _fetch_ohlcv_from_to(exc, name, timeframe; from=pair_from_date, to, out)
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
    data[name] = p
end

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
)
    local pb
    @assert !isempty(exc) "Bad exchange."
    exc_name = exc.name
    from, to = __ensure_dates(timeframe, from, to, exc_name)
    from_date = __from_date_func(update, timeframe, from, to, zi, exc_name, reset)
    data = Dict{String,PairData}()
    pb = progress && __print_progress_1(pairs)
    try
        for name in pairs
            ohlcv, z = __get_ohlcv(exc, name, timeframe, from_date, to)
            __pairdata!(zi, data, ohlcv, name, timeframe, z, exc_name, reset)
            progress && __print_progress_2(name, exc_name)
        end
    finally
        progress && @pbclose
    end
    data
end

function _fetch_candles(
    exc, timeframe, pairs::Iterable; from::D1, to::D2
) where {D1,D2<:Union{DateTime,AbstractString}}
    Dict(
        name => __get_ohlcv(exc, name, timeframe, Returns((nothing, from)), to)[1] for
        name in pairs
    )
end

function _fetch_candles(
    exc, timeframe, pair::AbstractString; from::D1, to::D2
) where {D1,D2<:Union{DateTime,AbstractString}}
    __get_ohlcv(exc, pair, timeframe, Returns((nothing, from)), to)[1]
end

function fetch_candles(
    exc::Exchange,
    timeframe::AbstractString,
    pairs::Union{AbstractString,Iterable};
    zi=zi[],
    from::DateType="",
    to::DateType="",
)
    from, to = __ensure_dates(timeframe, from, to, exc.name)
    _fetch_candles(exc, timeframe, pairs; from, to)
end

function fetch_candles(exc::Exchange, tf::TimeFrame, args...; kwargs...)
    fetch_candles(exc, string(tf), args...; kwargs...)
end

export fetch_ohlcv, fetch_candles
