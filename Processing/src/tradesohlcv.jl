module TradesOHLCV
using ..Misc.TimeTicks
using Data.DataFrames
using ..Processing: isincomplete

@doc "Returns the index where the data is *assumed* to end being contiguous.

That is we don't know if the last entries (trades) of the array, normalized to the last candle timestamp, was *all*
the trades for that particular candle.
"
function stopdateidx(v::AbstractVector, tf::TimeFrame; force=false)
    if force || isincomplete(last(v).timestamp, tf)
        to_date = apply(tf, last(v).timestamp)
        i = findfirst(x -> x.timestamp < to_date, @view(v[(end-1):-1:begin]))
        return isnothing(i) ? firstindex(v) - 1 : size(v, 1) - i
    end
    lastindex(v)
end

@doc "Returns the first index where the data is *assumed* to start being contiguous.

That is we don't know if the first entries (trades) of the array, normalized to the respective candle timestamp, was *all*
the trades for that particular candle.
"
function startdateidx(v::AbstractVector, tf::TimeFrame)
    from_date = apply(tf, first(v).timestamp) + tf.period
    i = findfirst(x -> x.timestamp >= from_date, @view(v[(begin+1):end]))
    isnothing(i) ? lastindex(v) : i + 1
end

const TRADES_COLS = [:timestamp, :price, :amount]
function to_ohlcv(df)
    gd = groupby(df, :timestamp; sort=true)
    combine(
        gd,
        :price => first => :open,
        :price => maximum => :high,
        :price => minimum => :low,
        :price => last => :close,
        :amount => sum => :volume,
    )
end

@doc "Converts a vector of values with (timestamp, price, amount) fields to OHLCV.

`tf`: the timeframe to build OHLCV for. [`1m`]
`trim_left`: skip starting candle. [`true`]
`trim_right`: skip end candle, if `false` candle will still be skipped if it is too recent wrt. the timeframe. [`true`]

Returns (;ohlcv, start, stop) where `start` and `stop` refer to the range of the input vector used to build the candles or `nothing` if no candles could be built.
"
function trades_to_ohlcv(
    v::AbstractVector, tf::TimeFrame=tf"1m"; trim_left=true, trim_right=true
)
    isempty(v) && return nothing
    start = trim_left ? startdateidx(v, tf) : 1
    stop = stopdateidx(v, tf; force=trim_right)
    start > stop && return nothing
    trades = length(start:stop) == length(v) ? v : view(v, start:stop)

    data = [getproperty.(trades, c) for c in TRADES_COLS]
    # FIXME
    data[1][:] = apply.(tf, data[1])
    df = DataFrame(data, TRADES_COLS; copycols=false)
    ohlcv = to_ohlcv(df)
    (; ohlcv, start, stop)
end

export trades_to_ohlcv

end
