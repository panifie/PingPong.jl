using Instruments
using TimeTicks
using Misc: DFT, FUNDING_PERIOD
using Instruments.Derivatives
using ExchangeTypes: exc
using Python: PyDict
using Processing: _fill_missing_candles

@doc """Retrieves all funding data return by exchange for symbol, or a subset.
```julia
funding_data(exc, "BTC/USDT:USDT")
funding_data(exc, "BTC/USDT:USDT", :fundingRate, :markPrice)
```
"""
function funding_data(exc::Exchange, s::AbstractString, syms...)
    fr = pyfetch(exc.fetchFundingRate, s)
    isempty(syms) || syms[1] == :all && return pyconvert(Dict, fr)
    Dict(s => fr[string(s)] for s in syms)
end
funding_data(exc, a::Derivative, args...) = funding_data(exc, a.raw)
funding_data(v, args...) = funding_data(exc, v, args...)

function pytofloat(v::Py, def=zero(DFT))
    if pyisinstance(v, pybuiltins.float)
        v
    elseif pyisinstance(v, pybuiltins.str)
        pyconvert(DFT, pyfloat(v))
    else
        def
    end
end

function funding_rate(exc::Exchange, s::AbstractString)
    resp = pyfetch(exc.fetchFundingRate, s)
    get(k, def) = pytofloat(resp[k], def)
    @something get("fundingRate", nothing) get("nextFundingRate", 0.0001)
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

@doc "Fetch funding rate history from exchange for a list of `Derivative` pairs.

- `from`, `to`: specify date period to fetch candles for."
function fetch_funding(
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
        (pair, since, limit) -> begin
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
        limit = get(futures_limits, nameof(exc.id), nothing)
    end
    ans = Dict(
        begin
            out = DataFrame(
                [DateTime[], String[], Float64[]], FUNDING_RATE_COLS; copycols=false
            )
            _fetch_loop(
                ff, exc, a; from, to, sleep_t, converter=extract_futures_data, limit, out
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

function _cleanup_funding_history(df, name, half_tf, f_tf)
    # normalize timestamps
    df.timestamp[:] = apply.(half_tf, df.timestamp)
    unique!(df, :timestamp)
    # resample to funding timestamp
    resample(df, half_tf, f_tf)
    # add close because of fill_missing_candles
    df[!, :close] .= 0.0
    buildf(ts, args...) = (; timestamp=ts, pair=name, rate=0.0001, close=NaN)
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

export fetch_funding, funding_rate
