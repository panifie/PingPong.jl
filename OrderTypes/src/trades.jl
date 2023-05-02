using Lang: @deassert
using Base: negate

signedamount(amount, ::BuyOrder) = amount
signedamount(amount, ::SellOrder) = negate(amount)
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
- size: The total quantity of quote currency exchanged (With fees and other additional costs.)
"""
struct Trade{
    O<:OrderType{S} where {S<:OrderSide},A<:AbstractAsset,E<:ExchangeID,P<:PositionSide
} <: AssetEvent{E}
    order::Order{O,A,E}
    date::DateTime
    amount::Float64
    price::Float64
    size::Float64
    function Trade(o::Order{O,A,E,P}, date, amount, price, size) where {O,A,E,P}
        @deassert amount > 0.0
        @deassert size > 0.0
        new{O,A,E,P}(o, date, signedamount(amount, o), price, signedsize(size, o))
    end
end

const BuyTrade{A,E,P} = Trade{<:OrderType{Buy},A,E,P}
const SellTrade{A,E,P} = Trade{<:OrderType{Sell},A,E,P}
const LongBuyTrade{A,E} = BuyTrade{A,E,Long}
const ShortBuyTrade{A,E} = BuyTrade{A,E,Short}
const LongSellTrade{A,E} = SellTrade{A,E,Long}
const ShortSellTrade{A,E} = SellTrade{A,E,Short}

exchangeid(::Trade{<:OrderType,<:AbstractAsset,E}) where {E<:ExchangeID} = E
