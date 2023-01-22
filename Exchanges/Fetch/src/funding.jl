using Instruments
using TimeTicks
using Instruments.Derivatives
using ExchangeTypes: exc
using Python: PyDict

@doc """Retrieves all funding data return by exchange for symbol, or a subset.
```julia
funding_data(exc, "BTC/USDT:USDT")
funding_data(exc, "BTC/USDT:USDT", :fundingRate, :markPrice)
```
"""
function funding_data(exc::Exchange, s::AbstractString, syms...)
    fr = exc.fetchFundingRate(s)[s]
    syms[1] == :all && return pyconvert(Dict, fr)
    Dict(s => fr[string(s)] for s in syms)
end
funding_data(exc, a::Derivative, args...) = funding_data(exc, a.raw)
funding_data(v, args...) = funding_data(exc, v, args...)
function funding_rate(exc::Exchange, s::AbstractString)
    pyconvert(Float64, exc.fetchFundingRate(s)[s]["fundingRate"])
end
funding_rate(exc, a::Derivative) = funding_rate(exc, a.raw)
funding_rate(v) = funding_rate(exc, v)

const FUNDING_RATE_COLUMNS = (:timestamp, :pair, :rate)
const FUNDING_RATE_COLS = [FUNDING_RATE_COLUMNS...]
function parse_funding_row(r::Py)
    pyconvert(Tuple{Int64,String,Float64}, (r["timestamp"], r["symbol"], r["fundingRate"]))
end
function extract_futures_data(data::Py)
    ts, sym, rate = DateTime[], String[], Float64[]
    for r in data
        push!(ts, dt(pyconvert(Int64, r["timestamp"])))
        push!(sym, pyconvert(String, r["symbol"]))
        push!(rate, pyconvert(Float64, r["fundingRate"]))
    end
    DataFrame([ts, sym, rate], FUNDING_RATE_COLS)
end

const futures_limits = IdDict(:binance => 1000)
const FUNDING_PERIOD = Hour(8)
@doc "Fetch funding rate history from exchange for a list of `Derivative` pairs.

- `from`, `to`: specify date period to fetch candles for."
function fetch_funding(
    exc::Exchange,
    assets::Vector;
    from::DateType="",
    to::DateType="",
    params=PyDict(),
    sleep_t=1,
    limit=nothing,
)
    from, to = from_to_dt(FUNDING_PERIOD, from, to)
    (from, to) = _check_from_to(from, to)
    ff =
        (pair, since, limit) -> begin
            try
                exc.py.fetchFundingRateHistory(pair; since, limit, params)
            catch err
                # HACK: `since` is supposed to be the timestamp of the beginning of the
                # period to fetch. However if it considered invalid, use a negative value
                # representing the milliseconds that have passed since the start date.
                if occursin("Time Is Invalid", string(err))
                    delta = -Int(timefloat(now() - dt(since)))
                    exc.py.fetchFundingRateHistory(pair; since=delta, limit, params)
                else
                    throw(err)
                end
            end
        end
    if isnothing(limit)
        limit = get(futures_limits, nameof(exc.id), nothing)
    end
    Dict(
        begin
            out = DataFrame(
                [DateTime[], String[], Float64[]], FUNDING_RATE_COLS; copycols=false
            )
            a => _fetch_loop(
                ff,
                exc,
                a.raw;
                from,
                to,
                sleep_t,
                converter=extract_futures_data,
                limit,
                out,
            )
        end for a in assets
    )
end
