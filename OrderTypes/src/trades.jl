using Lang: @deassert

signedamount(amount, ::LongBuyOrder) = amount
signedamount(amount, ::LongSellOrder) = -amount
signedamount(amount, ::ShortSellOrder) = -amount
signedamount(amount, ::ShortBuyOrder) = amount
signedsize(size, ::LongBuyOrder) = -size
signedsize(size, ::LongSellOrder) = size
signedsize(size, ::ShortSellOrder) = -size
signedsize(size, ::ShortBuyOrder) = size

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

const BuyTrade{O<:OrderType{Buy},A,E,P} = Trade{O,A,E,P}
const SellTrade{O<:OrderType{Sell},A,E,P} = Trade{O,A,E,P}
const LongBuyTrade{O,A,E} = BuyTrade{O,A,E,Long}
const ShortBuyTrade{O,A,E} = BuyTrade{O,A,E,Short}
const LongSellTrade{O,A,E} = SellTrade{O,A,E,Long}
const ShortSellTrade{O,A,E} = SellTrade{O,A,E,Short}

exchangeid(::Trade{<:OrderType,<:AbstractAsset,E}) where {E<:ExchangeID} = E
