module Orders
using Dates: DateTime, Period
using Misc: Candle
using TimeTicks
using Pairs
using ExchangeTypes
using Lang: Lang, @exportenum

@doc "A type to specify the reason why a buy or sell event has happened."
@enum OrderKind begin
    Take
    Stop
    Trailing
    Ladder
    Rebalance
end

@doc """An Order is either a buy or sell event, for an `AssetInstance`,
of a specif `OrderKind`. Positive amount is a buy, negative is a sell.

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
struct Order1{A<:Asset,E<:ExchangeID,OrderKind}
    asset::A
    exc::ExchangeID
    kind::OrderKind
    price::Float64
    amount::Float64
    date::DateTime
    Order1(a::A, e::E, k::OrderKind, amount) where {A<:Asset,E<:ExchangeID} = begin
        new{A,E,k}(a, e, k, amount)
    end
end
Order = Order1

@enum OrderAction close open

@doc """An order, successfully executed from a strategy request.
Open Orders: The date when the order was actually opened, during backtesting, it is usually `date + tf.period`
    where the timeframe depends on the backtesting `Context`. It should match a candle.

Close orders: wrap open orders. It should match the candle when the buy or sell happened.
"""
struct ExecutedOrder1{O<:Order,OrderAction}
    request::O
    candle::Candle
    date::DateTime
    rate::Float64
    ExecutedOrder1(o::O, action::OrderAction, candle, date, rate) where {O<:Order} = begin
        new{O,action}(o, candle, date, rate)
    end
end
ExecutedOrder = ExecutedOrder1

@doc """ A buy or sell event that has happened.
- order: The order received by the strategy
- price: The actual price of execution (accounting for spread)
- amount: The actual amount of the finalized trade (accounting for fees)
"""
struct Trade1{O}
    open::ExecutedOrder{O,open}
    close::ExecutedOrder{O,close}
    Trade(open_order, close_order) = begin
        new{O}(open_order, close_order)
    end
end
Trade = Trade1

@exportenum OrderKind
export OrderKind, Order, ExecutedOrder, Trade

end
