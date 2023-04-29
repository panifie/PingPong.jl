using Exchanges: market_limits, market_precision, market_fees

function Instances.AssetInstance(a; data, exc, margin, min_amount=1e-15)
    limits = market_limits(a.raw, exc; default_amount=(min=min_amount, max=Inf))
    precision = market_precision(a.raw, exc)
    fees = market_fees(a.raw, exc)
    AssetInstance(a, data, exc, margin; limits, precision, fees)
end
function Instances.AssetInstance(s::S, t::S, e::S, m::S) where {S<:AbstractString}
    a = parse(AbstractAsset, s)
    tf = convert(TimeFrame, t)
    exc = getexchange!(Symbol(e))
    margin = if m == "isolated"
        Isolated()
    elseif m == "cross"
        Cross()
    else
        NoMargin()
    end
    data = Dict(tf => load(zi, exc.name, a.raw, t))
    AssetInstance(a, data, exc, margin)
end
