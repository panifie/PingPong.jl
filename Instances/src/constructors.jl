using Exchanges: market_limits, market_precision, market_fees

@doc """ Creates an AssetInstance.

$(TYPEDSIGNATURES)

This function creates an AssetInstance with the specified asset (`a`), data, exchange (`exc`), margin, and an optional minimum amount (`min_amount`). If no minimum amount is provided, it defaults to 1e-15.

"""
function Instances.AssetInstance(a; data, exc, margin, min_amount=1e-15)
    precision = market_precision(a.raw, exc)
    limits = market_limits(a.raw, exc; default_amount=(min=min_amount, max=Inf), precision)
    fees = market_fees(a.raw, exc)
    AssetInstance(a, data, exc, margin; limits, precision, fees)
end
@doc """ Creates an AssetInstance from strings.

$(TYPEDSIGNATURES)

This function creates an AssetInstance using the provided strings for the asset (`s`), data type (`t`), exchange (`e`), and margin type (`m`).

"""
function Instances.AssetInstance(
    s::S, t::S, e::S, m::S; sandbox::Bool, params=nothing, account=""
) where {S<:AbstractString}
    a = parse(AbstractAsset, s)
    tf = convert(TimeFrame, t)
    exc = getexchange!(Symbol(e), params; sandbox, account)
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

function Instances.AssetInstance{AA,EID,MM}(sym; sandbox, params=nothing, account="") where {AA,EID,MM}
    AssetInstance(
        parse(AbstractAsset, sym);
        data=SortedDict{TimeFrame,DataFrame}(),
        exc=getexchange!(EID(), params; sandbox, account),
        margin=MM(),
    )
end
