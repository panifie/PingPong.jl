module Orders
using Misc: Candle, config
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
struct Order4{A<:AbstractAsset,E<:ExchangeID}
    asset::A
    exc::ExchangeID
    kind::OrderKind
    price::Float64
    amount::Float64
    date::DateTime
    function Order4(a::A, e::E, args...) where {A<:AbstractAsset,E<:ExchangeID}
        new{A, E}(a, e, args...)
    end
    function Order4(a::A, e::E; amount=config.base_amount, price=0.0, kind=Take, date=now()) where {A<:AbstractAsset,E<:ExchangeID}
        new{A,E}(a, e, kind, price, amount, date)
    end
end
Order = Order4

@doc """An order, successfully executed from a strategy request.
Entry trades: The date when the order was actually opened, during backtesting, it is usually `date + tf.period`
    where the timeframe depends on the backtesting `Context`. It should match a candle.
Exit trades: It should match the candle when the buy or sell happened.

- request: The order that spawned this trade.
- price: The actual price of execution (accounting for spread and slippage)
- amount: The actual amount of execution (accounting for fees)
- date: The date at which the trade (usually its last order) was completed.
"""
struct Trade7{O<:Order}
    request::O
    candle::Candle
    date::DateTime
    price::Float64
    amount::Float64
    function Trade7(o::O, candle, date, rate) where {O<:Order}
        begin
            new{O}(o, candle, date, rate)
        end
    end
end
Trade = Trade7

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

@exportenum OrderKind
export OrderKind, Order, Trade

end
