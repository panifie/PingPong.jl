using Data: load, to_ohlcv, zi, PairData, DataFrame, empty_ohlcv
using Ccxt
using Python
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
using Misc: _instantiate_workers, config, DATA_PATH, ohlcv_limits, drop
using Python
using TimeTicks
@debug using TimeTicks: dt
using Pbar
using Processing: cleanup_ohlcv_data, is_last_complete_candle

function _check_from_to(from::F, to::T) where {F,T<:DateType}
    from = timefloat(from)
    if to === ""
        to = timefloat(now())
    else
        to = timefloat(to)
        from > to &&
            @error "End date ($(to |> dt)) must be higher than start date ($(from |> dt))."
    end
    (from, to)
end

@doc "Ensure a `to` date is set, before fetching."
function _fetch_ohlcv_1(
    exc::Exchange, pair, timeframe; from="", to="", params=PyDict(), sleep_t=1, cleanup=true
)
    (from, to) = _check_from_to(from, to)
    @debug "Fetching pair $pair from exchange $(exc.name) at $timeframe - from: $(from |> dt) - to: $(to |> dt)."
    fetch_func =
        (pair, since, limit) -> pyfetch(exc.py.fetchOHLCV, pair; timeframe, since, limit, params)
    limit = fetch_limit(exc, nothing)
    data = _fetch_loop(fetch_func, exc, pair; from, to, sleep_t, limit)
    cleanup ? cleanup_ohlcv_data(data, timeframe) : data
end

@doc "Should return the oldest possible timestamp for a pair, or something close to it."
function find_since(exc::Exchange, pair)
    tfs = collect(exc.timeframes)
    periods = tfperiod.(tfs)
    order = sortperm(periods; rev=true)
    periods = @view periods[order]
    tfs = @view tfs[order]
    data = []
    for (t, p) in zip(tfs, periods)
        old_ts = Int(timefloat(Millisecond(p)))
        # fetch the first available candles using a long (1w) timeframe
        data = _fetch_ohlcv_with_delay(exc, pair; timeframe=t, since=old_ts, df=true)
        if !isempty(data)
            break
        end
    end
    if isempty(data)
        # try without `since` arg
        data = _fetch_ohlcv_with_delay(exc, pair; timeframe=tfs[begin], df=true)
    end
    # default to 1 day
    isempty(data) && return Int(timefloat(now() - Day(1)))
    Int(timefloat(data[begin, 1]))
end

function fetch_limit(exc::Exchange, limit::Option{Int})
    if isnothing(limit)
        get(ohlcv_limits, Symbol(lowercase(string(exc.name))), 1000)
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
    converter::Function=pylist_to_matrix,
    limit=nothing,
) where {F<:AbstractFloat}
    @debug "Downloading data for pair $pair."
    pair ∉ keys(exc.markets) && throw("Pair $pair not in exchange markets.")
    local since
    if from === 0.0
        since = find_since(exc, pair)
        @debug "since time: ", since
    else
        append!(
            out,
            _fetch_with_delay(fetch_func, pair; since=Int(from), df=true, limit, converter),
        )
        if size(out, 1) > 0
            since = Int(timefloat(out[end, 1]))
        else
            @debug "Couldn't fetch data for $pair from $(exc.name), too long dates? $(dt(from))."
            since = find_since(exc, pair)
        end
    end
    @debug "Starting from $(dt(since)) - to: $(dt(to))."
    while since < to
        sleep(sleep_t)
        fetched = _fetch_with_delay(fetch_func, pair; since, df=true, limit, converter)
        size(fetched, 1) === 0 && break
        append!(out, fetched)
        last_ts = Int(timefloat(out[end, 1]))
        since === last_ts && break
        since = last_ts
        @debug "Downloaded data for pair $pair up to $(since |> dt) from $(exc.name)."
    end
    return out
end

function pylist_to_matrix(data::Py)
    permutedims(reduce(hcat, pyconvert(Vector{<:Vector}, data)))
end

@doc """
Wraps a fetching function around error handling and backoff delay.
`fetch_func` signature:
(pair::String, since::Float, limit::Float) -> PyList
The `converter` function has to tabulate the data such that the first column is the timestamp
"""
function _fetch_with_delay(
    fetch_func::Function,
    pair;
    since=nothing,
    df=false,
    sleep_t=0,
    limit=nothing,
    converter=pylist_to_matrix,
)
    try
        @debug "Calling into ccxt to fetch data: $pair since $since"
        data = fetch_func(pair, since, limit)
        dpl = pyisinstance(data, @py(list))
        if !dpl
            @debug "Downloaded data is not a matrix...retrying (since: $(dt(since)))."
            sleep(sleep_t)
            sleep_t = (sleep_t + 1) * 2
            data = _fetch_with_delay(
                fetch_func, pair; since, df, sleep_t, limit=(limit ÷ 2), converter
            )
        end
        data = converter(data)
        # Apply conversion to fetched data
        if isempty(data) || size(data, 1) == 0
            return data isa DataFrame ? data : empty_ohlcv()
        end
        # @debug "Returning converted ohlcv data."
        (df && !(data isa DataFrame)) ? to_ohlcv(data) : data
    catch e
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
end

function _fetch_ohlcv_with_delay(exc::Exchange, args...; kwargs...)
    limit = get(kwargs, :limit, nothing)
    limit = fetch_limit(exc, limit)
    timeframe = get(kwargs, :timeframe, config.timeframe)
    params = get(kwargs, :params, PyDict())
    fetc_func =
        (pair, since, limit) -> pyfetch(exc.py.fetchOHLCV, pair; since, limit, timeframe, params)
    kwargs = collect((k, v) for (k, v) in kwargs if k ∉ (:params, :timeframe, :limit))
    _fetch_with_delay(fetc_func, args...; limit, kwargs...)
end
# FIXME: we assume the exchange class is set (is not pynull), if itsn't set PythonCall segfaults
function fetch_ohlcv(exc::Exchange, timeframe::AbstractString, pairs::StrOrVec; kwargs...)
    pairs = pairs isa String ? [pairs] : pairs
    fetch_ohlcv(exc, timeframe, pairs; kwargs...)
end
function fetch_ohlcv(timeframe::AbstractString, pairs::StrOrVec; kwargs...)
    fetch_ohlcv(exc, timeframe, pairs; kwargs...)
end
function fetch_ohlcv(exc::Exchange, timeframe::AbstractString; qc, kwargs...)
    pairs = get_pairlist(exc, qc; as_vec=true)
    fetch_ohlcv(exc, timeframe, pairs; kwargs...)
end
function fetch_ohlcv(timeframe::AbstractString; kwargs...)
    qc = :qc ∈ keys(kwargs) ? kwargs[:qc] : config.qc
    pairs = collect(keys(get_pairlist(exc, qc)))
    fetch_ohlcv(timeframe, pairs; filter(x -> x[1] !== :qc, kwargs)...)
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

@doc """Fetch ohlcv data from exchange for a list of pairs.
- `from`, `to`: Can represent a date. A negative `from` number implies fetching the last N=`from` candles.
- `update`: If true, will check for cached data, and fetch only missing candles. (`false`)
- `progress`: if true, show a progress bar. (`true`)
- `reset`: if true, will remove cached data before fetching. (`false`)
"""
function fetch_ohlcv(
    exc::Exchange,
    timeframe::AbstractString,
    pairs::AbstractVector;
    zi=zi,
    from::DateType="",
    to::DateType="",
    update=false,
    reset=false,
    progress=true,
)
    @assert !isempty(exc) "Bad exchange."
    exc_name = exc.name
    local za
    if !is_timeframe_supported(timeframe, exc)
        @error "Timeframe $timeframe not supported by exchange $exc_name."
    end
    from, to = from_to_dt(timeframe, from, to)
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
        from_date = (_) -> (nothing, from)
    end
    data = Dict{String,PairData}()
    @info "Downloading data for $(length(pairs)) pairs."
    progress && @pbar! pairs "Pairlist download progress" "pair" false
    try
        for name in pairs
            @debug "Fetching pair $name."
            z, pair_from_date = from_date(name)
            @debug "...from date $pair_from_date"
            if !is_last_complete_candle(pair_from_date, timeframe)
                ohlcv = _fetch_ohlcv_1(exc, name, timeframe; from=pair_from_date, to)
            else
                ohlcv = empty_ohlcv()
            end
            if size(ohlcv, 1) > 0
                try
                    z = save_ohlcv(zi[], exc_name, name, timeframe, ohlcv; reset)
                catch e
                    if e isa ContiguityException
                        z = save_ohlcv(zi[], exc_name, name, timeframe, ohlcv; reset=true)
                    elseif e isa AssertionError
                        display(e)
                        @warn "Could not fetch data for pair $name, check integrity of saved data."
                    else
                        rethrow(e)
                    end
                end
            elseif isnothing(z)
                z, _ = load(zi, exc_name, name, timeframe; as_z=true)
            end
            p = PairData(; name, tf=timeframe, data=ohlcv, z)
            data[name] = p
            @info "Fetched $(size(p.data, 1)) candles for $name from $(exc_name)"
            progress && @pbupdate!
        end
    finally
        progress && @pbclose
    end
    data
end

export fetch_ohlcv
