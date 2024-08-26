using Exchanges.Instruments
using .TimeTicks
using .Misc: DFT, FUNDING_PERIOD
using .Misc.TimeToLive
using .Misc.Lang: @lget!, @debug_backtrace
using .Instruments.Derivatives
using .Python: PyDict
using Processing: _fill_missing_candles
using Processing.Data: Not, select!

@doc """Retrieves all or a subset of funding data for a symbol from an exchange.

$(TYPEDSIGNATURES)

The `funding_data` function retrieves all funding data returned by an exchange `exc` for a symbol `sym`.
"""
function funding_data(exc::Exchange, sym::AbstractString)
    try
        pyfetch(exc.fetchFundingRate, sym)
    catch
        @debug_backtrace
    end
end
funding_data(exc, a::Derivative, args...) = funding_data(exc, a.raw)
funding_data(v, args...) = funding_data(exc, v, args...)

@doc """Retrieves the funding rate for a symbol from an exchange.

$(TYPEDSIGNATURES)

The `funding_rate` function retrieves the funding rate for a symbol `s` from an exchange `exc`.
"""
function funding_rate(exc::Exchange, s::AbstractString)
    id = exc.id
    @lget! FUNDING_RATE_CACHE (s, id) begin
        resp = if exc.has[:fetchFundingRates]
            rates = @lget! FUNDING_RATES_CACHE id pyfetch(exc.fetchFundingRates)
            rates[s]
        else
            pyfetch(exc.fetchFundingRate, s)
        end
        get(k) =
            let
                v = (resp.get(k))
                if Python.pyisTrue(pytype(v) == pybuiltins.str)
                    pytofloat(v)
                else
                    pyconvert(Option{DFT}, v)
                end
            end
        @something get("fundingRate") get("nextFundingRate") 0.00001
    end
end
funding_rate(exc, a::Derivative) = funding_rate(exc, a.raw)
funding_rate(ai) = funding_rate(ai.exchange, ai.asset)

const FUNDING_RATE_COLUMNS = (:timestamp, :pair, :rate)
const FUNDING_RATE_COLS = [FUNDING_RATE_COLUMNS...]
@doc """Parses a row of funding data from a Python object.

$(TYPEDSIGNATURES)

The `parse_funding_row` function takes a row of funding data `r` from a Python object and parses it into a format suitable for further processing or analysis.
"""
function parse_funding_row(r::Py)
    pyconvert(Tuple{Int64,String,Float64}, (r["timestamp"], r["symbol"], r["fundingRate"]))
end
@doc """Extracts futures data from a Python object.

$(TYPEDSIGNATURES)

The `extract_futures_data` function takes futures data `data` from a Python object and extracts it into a format suitable for further processing or analysis.
"""
function extract_futures_data(data::Py)
    ts, sym, rate = DateTime[], String[], Float64[]
    for r in data
        push!(ts, dt(pyconvert(Int64, r["timestamp"])))
        push!(sym, pyconvert(String, r["symbol"]))
        push!(rate, pyconvert(Float64, r["fundingRate"]))
    end
    DataFrame([ts, sym, rate], FUNDING_RATE_COLS)
end

@doc "Defines limit values for fetching futures data from exchanges."
const futures_limits = IdDict(:binance => 1000)

@doc """Fetches funding rate history from an exchange for a list of `Derivative` pairs.

$(TYPEDSIGNATURES)

The `funding_history` function fetches funding rate history from a given exchange `exc` for a list of `assets`. The `from` and `to` parameters define the date range for which to fetch the funding rate history. Additional parameters can be specified through the `params` dictionary. The function will wait for `sleep_t` seconds between each request to the exchange. The `limit` parameter can be used to limit the amount of data fetched. If `cleanup` is set to true, the function will perform a cleanup on the fetched data before returning it.
"""
function funding_history(
    exc::Exchange,
    assets::Vector;
    from::DateType="",
    to::DateType="",
    params=Dict(),
    sleep_t=1,
    limit=nothing,
    cleanup=true,
)
    from, to = from_to_dt(FUNDING_PERIOD, from, to)
    from, to = _check_from_to(from, to)
    ff =
        (pair, since, limit; kwargs...) -> begin
            try
                pyfetch(exc.py.fetchFundingRateHistory, pair; since, limit, params)
            catch err
                # HACK: `since` is supposed to be the timestamp of the beginning of the
                # period to fetch. However if it considered invalid, use a negative value
                # representing the milliseconds that have passed since the start date.
                if occursin("Time Is Invalid", string(err))
                    delta = -Int(timefloat(now() - dt(since)))
                    pyfetch(
                        exc.py.fetchFundingRateHistory, pair; since=delta, limit, params
                    )
                else
                    throw(err)
                end
            end
        end
    if isnothing(limit)
        limit = get(futures_limits, Symbol(exc.id), nothing)
    end
    ans = Dict(
        begin
            out = DataFrame(
                [DateTime[], String[], Float64[]], FUNDING_RATE_COLS; copycols=false
            )
            _fetch_loop(
                ff,
                exc,
                raw(a);
                from,
                to,
                sleep_t,
                converter=extract_futures_data,
                limit,
                out,
            )
            a => out
        end for a in assets
    )
    if cleanup
        # use a shorter timeframe to avoid overlapping
        half_tf = TimeFrame(Millisecond(FUNDING_PERIOD) / 2)
        f_tf = TimeFrame(Millisecond(FUNDING_PERIOD))
        for k in keys(ans)
            _cleanup_funding_history(ans[k], k, half_tf, f_tf)
        end
    end
    return ans
end

@doc """Cleans up fetched funding history data.

$(TYPEDSIGNATURES)

The `_cleanup_funding_history` function takes a DataFrame `df` of fetched funding history data for a `name` and performs cleanup operations on it. The `half_tf` and `f_tf` parameters are used in the cleanup process.
"""
function _cleanup_funding_history(df, name, half_tf, f_tf)
    # normalize timestamps
    df.timestamp[:] = apply.(half_tf, df.timestamp)
    unique!(df, :timestamp)
    # resample to funding timestamp
    resample(df, half_tf, f_tf)
    # add close because of fill_missing_candles
    df[!, :close] .= 0.0
    buildf(ts, args...) = (; timestamp=ts, pair=string(name), rate=0.0001, close=NaN)
    _fill_missing_candles(
        df,
        FUNDING_PERIOD;
        strategy=:custom,
        inplace=true,
        def_strategy=buildf,
        def_type=NamedTuple{
            (:timestamp, :pair, :rate, :close),Tuple{DateTime,String,DFT,DFT}
        },
    )
    # remove close after fills
    select!(df, Not(:close))
end

@doc "Defines the time-to-live (TTL) for a funding rate as 5 seconds."
const FUNDING_RATE_TTL = Ref(Second(5))
@doc "Initializes a safe TTL cache for storing funding rates with a specified TTL."
const FUNDING_RATE_CACHE = safettl(Tuple{String,Symbol}, DFT, FUNDING_RATE_TTL[])
@doc "Initializes a safe TTL cache for storing multiple funding rates with a specified TTL."
const FUNDING_RATES_CACHE = safettl(Symbol, Py, FUNDING_RATE_TTL[])
assetkey(ai) = (ai.raw, ai.exchange.id)

export funding_history, funding_rate
