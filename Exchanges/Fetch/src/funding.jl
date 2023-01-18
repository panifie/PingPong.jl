using Pairs
using ExchangeTypes: exc

funding(exc::Exchange, s::AbstractString, syms...) = begin
    fr = exc.fetchFundingRate(s)
    syms[1] == :all && return pyconvert(Dict, fr)
    Dict(s => fr[string(s)] for s in syms)
end
funding(exc::Exchange, s::AbstractString) = begin
    pyconvert(Float64, exc.fetchFundingRate(s)["fundingRate"])
end
funding(exc::Exchange, a::AbstractAsset, args...) = funding(exc, a.raw, args...)
funding(v, args...) = funding(exc, v, args...)

# _fetch_pair_funding_history(pair, timeframe,) =
