using OrderTypes: MarketOrderType, ExchangeID, PositionSide, PositionTrade
using Base: negate
import Instruments: cash!

const AnyMarketOrder{S<:OrderSide,P<:PositionSide} = Order{
    <:MarketOrderType{S},<:AbstractAsset,<:ExchangeID,P
}

function marketorder(
    s::Strategy, ai, amount; date, type, take=nothing, stop=nothing, price, kwargs...
)
    @price! ai take stop
    @amount! ai amount
    comm = committment(type, ai, price, amount)
    if iscommittable(s, type, comm, ai)
        basicorder(ai, price, amount, comm, SanitizeOff(); date, type, kwargs...)
    end
end

# function cash!(
#     s::NoMarginStrategy, ai, t::PositionTrade{P}{<:MarketOrderType{Buy}}
# ) where {P<:PositionSide}
#     @deassert t.size < 0.0
#     @deassert t.amount > 0.0
#     add!(s.cash, t.size)
#     @deassert s.cash >= 0.0
#     add!(ai.cash, t.amount)
# end
# function cash!(
#     s::NoMarginStrategy, ai, t::PositionTrade{P}{<:MarketOrderType{Sell}}
# ) where {P<:PositionSide}
#     @deassert t.size > 0.0
#     @deassert t.amount < 0.0
#     add!(s.cash, t.size)
#     add!(ai.cash, t.amount)
#     @deassert ai.cash >= 0.0
# end

const LongMarketBuyTrade = Trade{<:MarketOrderType{Buy},<:AbstractAsset,<:ExchangeID,Long}
const LongMarketSellTrade = Trade{<:MarketOrderType{Sell},<:AbstractAsset,<:ExchangeID,Long}

# FIXME: Should this be ≈/≉?
islastfill(t::Trade{<:MarketOrderType}) = true
isfirstfill(t::Trade{<:MarketOrderType}) = true
@doc "Does nothing since market orders are never queued."
fullfill!(::Strategy, _, o::AnyMarketOrder, ::Trade) = nothing
