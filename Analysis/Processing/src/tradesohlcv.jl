module TradesOHLCV
using TimeTicks
using DataFrames

@doc "Returns the index where the data is *assumed* to end being contiguous.

That is we don't know if the last entries (trades) of the array, normalized to the last candle timestamp, was *all*
the trades for that particular candle.
"
function stopdateidx(v::AbstractVector, tf::TimeFrame; force=false)
    if force || isincomplete(last(v).timestamp, tf)
        to_date = apply(tf, last(v).timestamp)
        for i in reverse(eachindex(@view(v[(end - 1):-1:begin])))
            v[i].timestamp < to_date && return i
        end
        return firstindex(v) - 1
    end
    lastindex(v)
end

@doc "Returns the first index where the data is *assumed* to start being contiguous.

That is we don't know if the first entries (trades) of the array, normalized to the respective candle timestamp, was *all*
the trades for that particular candle.
"
function startdateidx(v::AbstractVector, tf::TimeFrame)
    from_date = apply(tf, first(v).timestamp) + tf.period
    for i in eachindex(@view(v[(begin + 1):end]))
        if v[i].timestamp >= from_date
            return i
        end
    end
    lastindex(v)
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
    trades = if trim_left
        start = startdateidx(v, tf)
        stop = stopdateidx(v, tf; force=trim_right)
        start > stop && return nothing
        @view v[start:stop]
    else
        v
    end
    cols = [:timestamp, :price, :amount]
    data = [getproperty.(trades, c) for c in cols]
    # FIXME
    data[1][:] = apply.(tf, data[1])
    df = DataFrame(data, cols; copycols=false)
    gd = groupby(df, :timestamp; sort=true)
    ohlcv = combine(
        gd,
        :price => first => :open,
        :price => maximum => :high,
        :price => minimum => :low,
        :price => last => :close,
        :amount => sum => :volume,
    )
    (; ohlcv, start, stop)
end

export trades_to_ohlcv

end
