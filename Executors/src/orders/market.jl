using .OrderTypes: MarketOrderType, ExchangeID, PositionSide, PositionTrade
using Base: negate
import .Instruments: cash!

@doc """ Executes a market order.

$(TYPEDSIGNATURES)

This function takes a strategy, an ai, an amount, and other optional arguments such as date, type, take, stop, price, and kwargs. It executes a market order with the given parameters. If `skipcommit` is set to false (default), the order is committed. Returns nothing.
"""
function marketorder(
    s::Strategy,
    ai,
    amount;
    date,
    type,
    take=nothing,
    stop=nothing,
    price,
    skipcommit=false,
    kwargs...,
)
    @price! ai take stop
    if type <: ReduceOnlyOrder
        amount = min(ai.limits.amount.max, amount)
    else
        @amount! ai amount
    end
    comm = Ref(committment(type, ai, price, amount))
    @debug "create market order:" ai = raw(ai) price amount cash(ai) comm type is_comm = iscommittable(s, type, comm, ai)
    if skipcommit || iscommittable(s, type, comm, ai)
        basicorder(ai, price, amount, comm, SanitizeOff(); date, type, kwargs...)
    end
end
@doc "Defines a long market buy trade type."
const LongMarketBuyTrade = Trade{<:MarketOrderType{Buy},<:AbstractAsset,<:ExchangeID,Long}
@doc "Represents a long market sell trade on a certain exchange for a specific asset."
const LongMarketSellTrade = Trade{<:MarketOrderType{Sell},<:AbstractAsset,<:ExchangeID,Long}

# FIXME: Should this be ≈/≉?
islastfill(t::Trade{<:MarketOrderType}) = true
isfirstfill(t::Trade{<:MarketOrderType}) = true
