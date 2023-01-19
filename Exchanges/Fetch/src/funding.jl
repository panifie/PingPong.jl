using Pairs
using Pairs.Derivatives
using ExchangeTypes: exc
using Python: PyDict

function funding(exc::Exchange, s::AbstractString, syms...)
    fr = exc.fetchFundingRate(s)
    syms[1] == :all && return pyconvert(Dict, fr)
    Dict(s => fr[string(s)] for s in syms)
end
function funding(exc::Exchange, s::AbstractString)
    pyconvert(Float64, exc.fetchFundingRate(s)["fundingRate"])
end
funding(exc::Exchange, a::Derivative, args...) = funding(exc, a.raw, args...)
funding(v, args...) = funding(exc, v, args...)

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
@doc "Fetch funding rate history from exchange for a list of `Derivative` pairs."
function funding(
    exc::Exchange,
    timeframe::AbstractString,
    assets::Vector{Derivative};
    from::DateType="",
    to::DateType="",
    params=PyDict(),
    sleep_t=1,
    limit=nothing,
)
    from, to = from_to_dt(timeframe, from, to)
    (from, to) = _check_from_to(from, to)
    ff = (pair, since, limit) -> exc.py.fetchFundingRateHistory(pair; since, limit, params)
    if isnothing(limit)
        limit = get(futures_limits, nameof(exc.id), nothing)
    end
    out = DataFrame([DateTime[], String[], Float64[]], FUNDING_RATE_COLS; copycols=false)
    Dict(
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
        ) for a in assets
    )
end
