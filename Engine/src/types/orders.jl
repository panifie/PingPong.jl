module Orders
using Misc: config
using Data: Candle
using TimeTicks
using Instruments
using Exchanges
using Lang: Lang, @exportenum

@enum OrderType begin
    Limit
    Market
    Stop
    Ladder
    Rebalance
end

# TYPENUM
@doc """An Order is a container for trades, tied to an `AssetInstance`.
Its execution depends on the order implementation.
Positive amount is a buy, negative is a sell.

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
struct Order14{OrderType,A<:AbstractAsset,E<:ExchangeID}
    asset::A
    exc::E
    date::DateTime
    price::Float64
    amount::Float64
    attrs::NamedTuple
    function Order14(
        a::A,
        e::E;
        type=Limit,
        date=now(),
        price=0.0,
        amount=(config.base_amount),
        attrs=(;),
        kwargs...,
    ) where {A<:AbstractAsset,E<:ExchangeID}
        new{type,A,E}(a, e, date, price, amount, attrs)
    end
end
Order = Order14

# TYPENUM
@doc """An order, successfully executed from a strategy request.
Entry trades: The date when the order was actually opened, during backtesting, it is usually `date + tf.period`
    where the timeframe depends on the backtesting `Context`. It should match a candle.
Exit trades: It should match the candle when the buy or sell happened.

- request: The order that spawned this trade.
- price: The actual price of execution (accounting for spread and slippage)
- amount: The actual amount of execution (accounting for fees)
- date: The date at which the trade (usually its last order) was completed.
"""
struct Trade8{O<:Order}
    request::O
    candle::Candle
    date::DateTime
    price::Float64
    amount::Float64
    function Trade8(o::O, candle, date, rate) where {O<:Order}
        new{O}(o, candle, date, rate)
    end
end
Trade = Trade8

# TYPENUM
@doc "A composite trade groups all the trades belonging to an order request.
- `trades`: the sequence of trades that matched the order.
- `rateavg`: the average price across all trades.
- `feestot`: sum of all fees incurred order trades.
- `amounttot`: sum of all the trades amount (~ Order amount).
"
struct CompositeTrade2{O<:Order}
    request::O
    trades::Vector{Trade{O}}
    priceavg::Float64
    feestot::Float64
    amounttot::Float64
end
CompositeTrade = CompositeTrade2

@exportenum OrderType
export Order, OrderType, Trade

end
