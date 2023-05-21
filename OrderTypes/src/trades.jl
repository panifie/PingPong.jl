using Lang: @deassert
using Base: negate
using Misc: DFT

signedamount(amount, ::AnyBuyOrder) = amount
signedamount(amount, ::AnySellOrder) = negate(amount)
signedsize(size, ::IncreaseOrder) = negate(size)
signedsize(size, ::ReduceOrder) = size

@doc """An order, successfully executed from a strategy request.
Entry trades: The date when the order was actually opened, during backtesting, it is usually `date + tf.period`
    where the timeframe depends on the backtesting `Context`. It should match a candle.
Exit trades: It should match the candle when the buy or sell happened.

- order: The order that spawned this trade.
- date: The date at which the trade (usually its last order) was completed.
- amount: The quantity of the base currency being exchanged
- price: The actual price (quote currency) of the trade, after slippage.
- value: price * amount
- fees: the fees paid for the trade, in quote currency.
- size: value +/- fees
- leverage: the leverage the trade was executed with
"""
struct Trade{
    O<:OrderType{S} where {S<:OrderSide},A<:AbstractAsset,E<:ExchangeID,P<:PositionSide
} <: AssetEvent{E}
    order::Order{O,A,E,P}
    date::DateTime
    amount::DFT
    price::DFT
    value::DFT
    fees::DFT
    size::DFT
    leverage::DFT
    entryprice::DFT
    function Trade(
        o::Order{O,A,E,P}; date, amount, price, fees, size, lev=1.0, entryprice=price
    ) where {O,A,E,P}
        @deassert amount > 0.0
        @deassert size > 0.0
        @deassert abs(amount) <= abs(o.amount)
        amount = signedamount(amount, o)
        value = abs(amount * price)
        new{O,A,E,P}(
            o, date, amount, price, value, fees, signedsize(size, o), lev, entryprice
        )
    end
end

const LongTrade{O,A,E} = Trade{O,A,E,Long}
const ShortTrade{O,A,E} = Trade{O,A,E,Short}
const BuyTrade{A,E} = Trade{<:OrderType{Buy},A,E,Long}
const SellTrade{A,E} = Trade{<:OrderType{Sell},A,E,Long}
const ShortBuyTrade{A,E} = Trade{<:OrderType{Buy},A,E,Short}
const ShortSellTrade{A,E} = Trade{<:OrderType{Sell},A,E,Short}
const IncreaseTrade{A,E} = Union{BuyTrade{A,E},ShortSellTrade{A,E}}
const ReduceTrade{A,E} = Union{SellTrade{A,E},ShortBuyTrade{A,E}}
const PositionTrade{P} = Trade{O,A,E,P} where {O<:OrderType,A<:AbstractAsset,E<:ExchangeID}
const LiquidationTrade{S} = Trade{<:LiquidationType{S}}

exchangeid(::Trade{<:OrderType,<:AbstractAsset,E}) where {E<:ExchangeID} = E
function positionside(
    ::Trade{<:OrderType,<:AbstractAsset,<:ExchangeID,P}
) where {P<:PositionSide}
    P
end
function orderside(
    ::Trade{<:OrderType{S},<:AbstractAsset,<:ExchangeID,<:PositionSide}
) where {S<:OrderSide}
    S
end
ordertype(::Trade{O}) where {O<:OrderType} = O
islong(o::LongTrade) = true
islong(o::ShortTrade) = false
isshort(o::LongTrade) = false
isshort(o::ShortTrade) = true
ispos(pos::PositionSide, t::Trade) = positionside(t) == pos
