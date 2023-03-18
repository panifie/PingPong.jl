module Orders
using Misc: config
using Data: Candle
using TimeTicks
using Instruments
using Exchanges
using Lang: Lang

abstract type OrderSide end
abstract type Buy <: OrderSide end
abstract type Sell <: OrderSide end

abstract type OrderType{S<:OrderSide} end
abstract type LimitOrderType{S} <: OrderType{S} end
abstract type FOKOrderType{S} <: OrderType{S} end
abstract type MarketOrderType{S} <: OrderType{S} end
# struct LadderOrder <: OrderType end
# struct RebalanceOrder <: OrderType end

# TYPENUM
@doc """An Order is a container for trades, tied to an asset and an exchange.
Its execution depends on the order implementation.

`date`: the time at which the strategy requested the order.
    The strategy is assumed to have *knowledge* of the ohlcv data \
    strictly lower than the timeframe adjusted date.
    Example:
    ```julia
    ts = dt"2020-05-24T02:34:00" # the date of the order request
    tf = @infertf ohlcv # get the timeframe (15m)
    start_date = ohlcv.timestamp[begin]
    stop_date = apply(tf, ts) # normalize date to timeframe
    stop_date -= tf.period # scale down by one timeframe step
    # At this point the stop date would be `2020-05-24T02:30:00`
    # which covers the period between ...02:30:00..02:45:00...
    # Therefore the strategy can only have access to data < 02:30:00
    avail_ohlcv = ohlcv[DateRange(start_date, stop_date), :]
    @assert isless(avail_ohlcv.timestamp[end], dt"2020-05-24T02:30:00")
    @assert isequal(avail_ohlcv.timestamp[end] + tf.period, dt"2020-05-24T02:30:00")
    ```
 """
struct Order15{T<:OrderType{S} where {S<:OrderSide},A<:AbstractAsset,E<:ExchangeID}
    asset::A
    exc::E
    date::DateTime
    price::Float64
    amount::Float64
    attrs::NamedTuple
end
Order = Order15
function Order15(
    a::A,
    e::E,
    ::Type{Order{T}}=LimitOrder{Buy};
    price,
    date=now(),
    amount=(config.min_amount),
    attrs=(;),
    kwargs...,
) where {T<:OrderType,A<:AbstractAsset,E<:ExchangeID}
    Order{T,A,E}(a, e, date, price, amount, attrs)
end
const BuyOrder{O,A,E} =
    Order{O,A,E} where {O<:OrderType{Buy},A<:AbstractAsset,E<:ExchangeID}
const SellOrder{O,A,E} =
    Order{O,A,E} where {O<:OrderType{Sell},A<:AbstractAsset,E<:ExchangeID}
macro deforders(types...)
    out = quote end
    for t in types
        type_str = string(t)
        type = esc(Symbol(type_str * "Order"))
        supertype = esc(Symbol(type_str * "OrderType"))
        push!(
            out.args,
            quote
                const $type{S,A,E} = Order{
                    $supertype{S},A,E
                } where {S<:OrderSide,A<:AbstractAsset,E<:ExchangeID}
            end,
        )
    end
    out
end
@deforders Limit FOK Market

# TYPENUM
@doc """An order, successfully executed from a strategy request.
Entry trades: The date when the order was actually opened, during backtesting, it is usually `date + tf.period`
    where the timeframe depends on the backtesting `Context`. It should match a candle.
Exit trades: It should match the candle when the buy or sell happened.

- request: The order that spawned this trade.
- date: The date at which the trade (usually its last order) was completed.
- amount: The quantity of the base currency being exchanged
- size: The total quantity of quote currency exchanged (With fees and other additional costs.)
"""
struct Trade10{O<:OrderType{S} where {S<:OrderSide},A<:AbstractAsset,E<:ExchangeID}
    order::Order{O,A,E}
    date::DateTime
    amount::Float64
    size::Float64
    function Trade10(o::Order{O,A,E}, date, amount, size) where {O,A,E}
        new{O,A,E}(o, date, amount, size)
    end
end
Trade = Trade10
const BuyTrade{O,A,E} =
    Trade{O,A,E} where {O<:OrderType{Buy},A<:AbstractAsset,E<:ExchangeID}
const SellTrade{O,A,E} =
    Trade{O,A,E} where {O<:OrderType{Sell},A<:AbstractAsset,E<:ExchangeID}

# TYPENUM
@doc "A composite trade groups all the trades belonging to an order request.
- `trades`: the sequence of trades that matched the order.
- `rateavg`: the average price across all trades.
- `feestot`: sum of all fees incurred order trades.
- `amounttot`: sum of all the trades amount (~ Order amount).
"
struct CompositeTrade3{O<:Order}
    request::O
    trades::Vector{Trade{O}}
    priceavg::Float64
    feestot::Float64
    amounttot::Float64
end
CompositeTrade = CompositeTrade3

const ordersdefault! = Returns(nothing)

export Order, OrderType, OrderSide, Buy, Sell
export BuyOrder, SellOrder, BuyTrade, SellTrade
export LimitOrder, MarketOrder, FOKOrder, Trade
export ordersdefault!

end
