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
using Exchanges.Python
using Processing: cleanup_ohlcv_data, islast, resample, Processing
using Processing.Pbar
using .Python: pylist_to_matrix, pytofloat
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
using .Data.DFUtils: lastdate, colnames, addcols!, copysubs!
using .Data.DataStructures: SortedDict
using .Data.Misc
using .Data.Cache: save_cache, load_cache
using .Misc: _instantiate_workers, config, DATA_PATH, fetch_limits, drop, StrOrVec, Iterable
using .Misc.TimeTicks
using .Misc.DocStringExtensions
using .TimeTicks: TimeFrameOrStr, timestamp, dtstamp
using .Misc.Lang: @distributed, @parallel, Option, filterkws, @ifdebug, @deassert
@ifdebug using .TimeTicks: dt

@doc "Used to slide the `since` param forward when retrying fetching (in case the requested timestamp is too old)."
const SINCE_MIN_PERIOD = Millisecond(Day(30))

function _to_candle(py, idx, range)
    Candle(dt(pyconvert(Float64, py[idx])), (to_float(py[n]) for n in range)...)
end
Base.convert(::Type{Candle}, py::PyList) = _to_candle(py, 1, 2:6)
Base.convert(::Type{Candle}, py::Py) = _to_candle(py, 0, 1:5)
_pytoval(::Type{DateTime}, v) = dt(to_float(v))
_pytoval(t::Type, v) = @something pyconvert(t, v) Data.default_value(t)
_pytoval(t::Type, v, def) = @something pyconvert(t, v) def
@doc "Defines the tuple type for OHLCV data, where each element represents a specific metric (Open, High, Low, Close, Volume)."
const OHLCVTupleTypes = (DateTime, fill(Float64, 4)..., Option{Float64})
# const OHLCVTupleTypes = (DateTime, (Float64 for _ in 1:4)..., Option{Float64})
@doc """ This is the fastest (afaik) way to convert ccxt lists to dataframe friendly format.

$(TYPEDSIGNATURES)

This function converts the provided Python object to a tuple format suitable for dataframes, specifically tailored for OHLCV data.

"""
function Base.convert(::Type{OHLCVTuple}, py::Py)
    vecs = ohlcvtuple()
    loopcols((c, v)) = push!(vecs[c], _pytoval(OHLCVTupleTypes[c], v))
    looprows(cdl) = foreach(loopcols, enumerate(cdl))
    foreach(looprows, py)
    vecs
end
_to_ohlcv_vecs(v)::OHLCVTuple = convert(OHLCVTuple, v)
@doc """ Converts a Python object to a DataFrame with OHLCV columns

$(TYPEDSIGNATURES)

"""
Data.to_ohlcv(py::Py) = DataFrame(_to_ohlcv_vecs(py), OHLCV_COLUMNS)

function _check_from_to(from::F, to::T) where {F,T<:DateType}
    from = isnothing(from) ? nothing : timefloat(from)
    if to === ""
        to = timefloat(now())
    else
        to = timefloat(to)
        if !isnothing(from) && from > to
            @error "fetch: end date higher than start date" from to
            from = nothing
        end
    end
    (from, to)
end

@doc """ Ensure a `to` date is set, before fetching.

$(TYPEDSIGNATURES)

This function verifies that a 'to' date is set before attempting to fetch OHLCV data.

"""
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
    py_fetch_func = ohlcv_func_bykind(exc, ohlcv_kind)
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

@doc """ Returns an ordered list of timeframes for a given exchange

$(TYPEDSIGNATURES)

This function collects the timeframes from the exchange, converts them into periods, and sorts them in descending order. It then returns these sorted timeframes and periods.

"""
function __ordered_timeframes(exc::Exchange)
    tfs = collect(exc.timeframes)
    periods = period.(convert.(TimeFrame, tfs))
    order = sortperm(periods; rev=true)
    periods = @view periods[order]
    tfs = @view tfs[order]
    tfs, periods
end

@doc """ Determines the start time for fetching data

$(TYPEDSIGNATURES)

This function calculates the timestamp from which to start fetching data. It ensures that the start time is not more than 20 years in the past or less than the given period.

"""
function _since_timestamp(actual::DateTime, p::Period)
    date = max(actual - Year(20), actual - 1000 * Millisecond(p))
    dtstamp(date, Val(:round))
end

@doc """ Returns the oldest possible timestamp for a pair.

$(TYPEDSIGNATURES)

This function iterates over the timeframes and periods of the exchange to find the oldest available timestamp for a given pair. If no data is found in any timeframe, it defaults to 1 day in the past.

"""
function find_since(exc::Exchange, pair)
    cache_key = string(exc.name, "-", pair)
    cached_since = load_cache(cache_key; raise=false)
    @something cached_since begin
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
        ans = dtstamp(isempty(data) ? now() - Day(1) : data[begin, 1], Val(:round))
        save_cache(cache_key, ans)
        ans
    end
end

@doc """ Defines the fetch limit for an exchange.

$(TYPEDSIGNATURES)

This function fetches the limit for an exchange. If no limit is specified, it retrieves the default limit for the exchange.

"""
function fetch_limit(exc::Exchange, limit::Option{Int})
    if isnothing(limit)
        get(fetch_limits, Symbol(lowercase(string(exc.name))), 1000)
    end
end

@doc """Determines the 'since' parameter for fetching data from an exchange.

$(TYPEDSIGNATURES)

This function calculates the 'since' parameter based on the specified 'from' timestamp, or finds the appropriate 'since' value if 'from' is 0.0.
"""
function __get_since(exc, fetch_func, pair, limit, from, out, is_df, converter)
    if from isa Number && !iszero(from)
        since_ts = round(Int, from, RoundUp)
        append!(
            out,
            _fetch_with_delay(fetch_func, pair; since=since_ts, df=is_df, limit, converter);
            cols=:union,
        )
        if size(out, 1) > 0
            first_date = apply(tf"1d", out[begin, :timestamp])
            since_date = apply(tf"1d", dt(since_ts))
            # TODO: this is too noisy, it should also check that the requested
            # period is smaller than the fetch limit
            if since_date != DateTime(0) && first_date > since_date
                @warn "fetch: ($(nameof(exc))) likely ignores `since` argument" since_date dt(
                    since_ts
                ) dt(from) pair maxlog = 1
            end
            round(Int, timefloat(out[end, 1]), RoundUp)
        else
            @debug "fetch: failed since guess for $pair from $(exc.name), too long dates? $(dt(from))."
            find_since(exc, pair)
        end
    else
        find_since(exc, pair)
    end
end

@doc """Iteratively fetches data over a specified date range.

$(TYPEDSIGNATURES)

This function calls the `fetch_func` function repeatedly until it has fetched data for the entire date range specified by `from` and `to`. Note: The total data points fetched may not match the expected number based on the date range.
"""
function _fetch_loop(
    fetch_func::Function,
    exc::Exchange,
    pair;
    from::Option{F},
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
    since = let v = __get_since(exc, fetch_func, pair, limit, from, out, is_df, converter)
        since_param(exc, v)
    end
    @debug "since time: ", since
    @debug "Starting from $(dt(since)) - to: $(dt(to))."
    function dofetch()
        sleep(sleep_t)
        fetched = _fetch_with_delay(fetch_func, pair; since, df=is_df, limit, converter)
        last_fetched_count[] = size(fetched, 1)
        size(fetched, 1) == 0 ? false : (append!(out, fetched); true)
    end
    lastts(out) = round(Int, timefloat(out[end, 1]), RoundUp)
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

@doc """Handles errors during fetch operations.

$(TYPEDSIGNATURES)

This function takes an error `e` occurred during data fetching, and decides whether to retry the `fetch_func` based on the `retry` flag. If `retry` is true, it calls the `fetch_func` again with the same parameters.
"""
function __handle_error(e, fetch_func, pair, since, df, sleep_t, limit, converter, retry)
    !retry && @return_empty()
    if e isa TaskFailedException
        e = e.task.result
    end
    if e isa PyException
        if !isnothing(match(r"429([0]+)?", string(e._v)))
            @debug "fetch: exchange error 429, too many requests."
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
        elseif isccxterror(e)
            @error "fetch: failed fetch ohlcv" pair exception = e
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

@doc """Handles fetch operations for specified exchange and pair.

$(TYPEDSIGNATURES)

This function calls the `fetch_func` for a given `pair`, starting from the `since` timestamp with a maximum limit of `limit` data points. It employs a delay `sleep_t` between fetches. The function also applies a given `converter` to the fetched data. If the `retry` flag is true, the function will try to fetch data again in case of an empty response. The `usetimeframe` flag indicates whether to use timeframe for fetching.
"""
function __handle_fetch(
    fetch_func, pair, since, limit, sleep_t, df, converter, retry, usetimeframe
)
    @debug "Calling into ccxt to fetch data: $pair since $(dt(since)), max: $limit, tf: $usetimeframe"
    data = fetch_func(pair, since, limit; usetimeframe)
    dpl = pyisinstance(data, @py(list))
    if retry && (!dpl || length(data) == 0)
        if data isa Exception
            @warn "fetch ohlcv: unexpected value (retrying)" data
        else
            @debug "fetch ohlcv: response (retrying)" data since
        end
        sleep(sleep_t)
        kwargs = if isnothing(since)
            (; since, limit=limit ÷ 2)
        else
            ofs = max(timefloat(Day(1)), timefloat(now() - dt(since)) / 2.0)
            tmp = since + round(Int, ofs, RoundUp)
            if tmp > dtstamp(now())
                (; since=nothing, limit=2000)
            else
                (; since=tmp, limit=max(10, something(limit, 20) ÷ 2))
            end
        end
        return (
            true,
            _fetch_with_delay(
                fetch_func,
                pair;
                kwargs...,
                df,
                sleep_t,
                converter,
                retry=!isnothing(since) && kwargs[:limit] > 10,
                usetimeframe,
            ),
        )
    end
    (false, data)
end

@doc """Wraps fetching function with error handling and backoff delay.

$(TYPEDSIGNATURES)

This function wraps a fetching function `fetch_func` with error handling and a backoff delay `sleep_t`. The `fetch_func` takes three parameters: `pair`, `since`, and `limit`, and returns a PyList. The `converter` function is used to tabulate the data such that the first column is the timestamp. The function will retry fetching in case of an error if `retry` is set to true.
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
        e isa InterruptException && rethrow(e)
        __handle_error(e, fetch_func, pair, since, df, sleep_t, limit, converter, retry)
    end
end

@doc """Returns the appropriate OHLCV fetching function based on the specified kind.

$(TYPEDSIGNATURES)

The `ohlcv_func_bykind` function determines and returns the appropriate OHLCV fetching function for the given exchange `exc` and `kind`.
"""
function ohlcv_func_bykind(exc, kind)
    args = if kind == :mark
        (:fetchMarkOHLCVWs, :fetchMarkOHLCV)
    elseif kind == :index
        (:fetchIndexOHLCVWs, :fetchIndexOHLCV)
    elseif kind == :premium
        (:fetchPremiumIndexOHLCVWs, :fetchPremiumIndexOHLCV)
    else
        (:fetchOHLCVWs, :fetchOHLCV)
    end
    first(exc, args...)
end

@doc """Fetches OHLCV data with delay for a given exchange and arguments.

$(TYPEDSIGNATURES)

This function fetches OHLCV data for a specified exchange `exc` and additional `args`. The type of OHLCV data to fetch is determined by `ohlcv_kind`. It applies a delay between fetches as specified in `kwargs`.
"""
function _fetch_ohlcv_with_delay(exc::Exchange, args...; ohlcv_kind=:default, kwargs...)
    limit = get(kwargs, :limit, nothing)
    limit = fetch_limit(exc, limit)
    timeframe = get(kwargs, :timeframe, config.min_timeframe)
    params = get(kwargs, :params, PyDict())
    py_fetch_func = ohlcv_func_bykind(exc, ohlcv_kind)
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

@doc """Ensures dates are within valid range for the exchange and timeframe.

$(TYPEDSIGNATURES)

The `__ensure_dates` function checks if the dates `from` and `to` are within the valid range for the given exchange `exc` and timeframe `tf`. If the dates are not within the valid range, the function adjusts them accordingly.
"""
function __ensure_dates(exc, tf, from, to)
    if !issupported(string(tf), exc)
        error("Timeframe $tf not supported by exchange $(exc.name).")
    end
    from_to_dt(tf, from, to)
end

@doc """Determines the starting date for fetching data.

$(TYPEDSIGNATURES)

The `__from_date_func` function determines the starting date `from` for fetching data based on various parameters. If `update` is true, it will fetch data from the latest date available. If `reset` is true, it will fetch data from the earliest date possible. The function also considers the `timeframe`, `to` date, timezone `zi`, and exchange name `exc_name` in its calculations.
"""
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

@doc """Fetches OHLCV data for a specified exchange within a date range.

$(TYPEDSIGNATURES)

This function fetches OHLCV data for a given exchange `exc`, with the specified `name` and `timeframe`, within the date range specified by `from_date` and `to`. The fetched data is appended to the `out` data structure. The `cleanup` parameter determines if any post-processing should be done on the data before returning. The `ohlcv_kind` parameter determines the type of OHLCV data to fetch.
"""
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
        e isa InterruptException && rethrow(e)
        __handle_save_ohlcv_error(e, exc_name, name, timeframe, ohlcv)
    end
end

@doc """Processes OHLCV data for a pair.

$(TYPEDSIGNATURES)

The `__pairdata!` function processes the OHLCV data `ohlcv` for a pair `name` over a `timeframe`. It takes into account the timezone `zi`, data `data`, timezone offset `z`, exchange name `exc_name`, and a `reset` flag. If `reset` is true, it will reset the data for the pair before processing.
"""
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
@doc """Fetches OHLCV data from an exchange for a list of pairs.

$(TYPEDSIGNATURES)

This function fetches OHLCV data from a given exchange `exc` for a list of `pairs` over a specified `timeframe`. The `from` and `to` parameters can represent dates or, if `from` is a negative number, the function fetches the last N=`from` candles. If `update` is true, the function checks for cached data and only fetches missing candles. If `reset` is true, the function removes cached data before fetching. The `progress` parameter determines whether a progress bar is shown. The type of OHLCV data to fetch is defined by the `ohlcv_kind` parameter.
"""
function fetch_ohlcv(
    exc::Exchange,
    timeframe::String,
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
        asyncmap(data!, pairs)
    finally
        progress && @pbstop!
    end
    data
end

@doc """Updates the tail of an OHLCV DataFrame with the most recent candles.

$(TYPEDSIGNATURES)

The `update_ohlcv!` function updates the tail of an OHLCV DataFrame `df` with the most recent candles for a given `pair` from an exchange `exc` over a timeframe `tf`. The type of OHLCV data to update is determined by the `ohlcv_kind` parameter.
"""
function update_ohlcv!(df::DataFrame, pair, exc, tf; ohlcv_kind=:default, from=nothing)
    from = if isempty(df)
        from
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
    if isnothing(from) || from isa Number
    elseif dt(from) < dt"2010-01-01"
        @warn "fetch: old from date" from
    elseif islast(dt(from), tf)
        @debug "fetch: from date too early" from
    end
    cleaned = _fetch_ohlcv_from_to(
        exc, pair, string(tf); from, to=now(), cleanup=true, ohlcv_kind
    )
    Data.DFUtils.addcols!(cleaned, df)
    copysubs!(df, empty, empty!)
    append!(df, cleaned)
end

@doc """Propagates OHLCV data to all timeframes in a data structure.

$(TYPEDSIGNATURES)

The `propagate_ohlcv!` function propagates OHLCV data for a given `pair` from an exchange `exc` to all timeframes in the `data` SortedDict data structure.
"""
function propagate_ohlcv!(data::SortedDict, pair::AbstractString, exc::Exchange)
    function doupdate!(base_tf, base_data, tf, tf_data)
        let res = resample(base_data, base_tf, tf)
            addcols!(res, tf_data)
            append!(tf_data, res)
        end
        let tmp = cleanup_ohlcv_data(tf_data, tf)
            addcols!(tmp, tf_data)
            copysubs!(tf_data, empty, empty!)
            append!(tf_data, tmp)
        end
        update_ohlcv!(tf_data, pair, exc, tf)
    end
    propagate_ohlcv!(data, doupdate!)
end

function _fetch_candles(exc, timeframe, pairs::Iterable; kwargs...)
    tasks = [name => _fetch_candles(exc, timeframe, name; kwargs...) for name in pairs]
    Dict(el.first => fetch(el.second) for el in tasks)
end

function _fetch_candles(
    exc, timeframe, pair::AbstractString; from::D1, to::D2, ohlcv_kind=:default
) where {D1,D2<:Union{DateTime,AbstractString}}
    __get_ohlcv(
        exc, pair, timeframe, Returns((nothing, from)), to; cleanup=false, ohlcv_kind
    )[1]
end

@doc """Fetches candlestick data for a list of pairs from an exchange.

$(TYPEDSIGNATURES)

The `fetch_candles` function fetches candlestick data from a given exchange `exc` for a list of `pairs` over a specified `timeframe`. The `from` and `to` parameters define the date range for the fetched data. If `from` is not provided, it defaults to an empty string, which implies fetching data from the earliest available date. The type of candlestick data to fetch is determined by the `ohlcv_kind` parameter.
"""
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

include("dispatch.jl")

export fetch_ohlcv, fetch_candles
