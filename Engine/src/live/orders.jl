module Orders
using Dates: DateTime, Period
using ..Trades: Order, Signal
using ..Instances: AssetInstance
using TimeTicks
using Lang

@doc """A live order tracks in flight trades.

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
 `delay`: how much time has passed since the order request \
          and the exchange execution of the order (to account for api issues).
 """
mutable struct LiveOrder2{I<:AssetInstance}
    signal::Signal
    amount::Float64
    asset::Ref{I}
    date::DateTime
    delay::Millisecond
    LiveOrder2(a::I, o::Order; date=nothing, delay=Millisecond(0)) where {I<:AssetInstance} = begin
        new{I}(o.signal, o.amount, a, date, delay)
    end
end

LiveOrder = LiveOrder2

export LiveOrder

end
