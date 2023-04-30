# TYPENUM
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
struct Trade{O<:OrderType{S} where {S<:OrderSide},A<:AbstractAsset,E<:ExchangeID} <:
       AssetEvent{E}
    order::Order{O,A,E}
    date::DateTime
    amount::Float64
    price::Float64
    size::Float64
    function Trade(o::Order{O,A,E}, date, amount, price, size) where {O,A,E}
        new{O,A,E}(o, date, amount, price, size)
    end
end

const BuyTrade{O,A,E} =
    Trade{O,A,E} where {O<:OrderType{Buy},A<:AbstractAsset,E<:ExchangeID}
const SellTrade{O,A,E} =
    Trade{O,A,E} where {O<:OrderType{Sell},A<:AbstractAsset,E<:ExchangeID}
exchangeid(::Trade{<:OrderType,<:AbstractAsset,E}) where {E<:ExchangeID} = E
