module TradesOHLCV
using ..Misc.TimeTicks
using ..Misc.DocStringExtensions
using Data.DataFrames
using ..Processing: isincomplete

@doc "Returns the index where the data is *assumed* to end being contiguous.

$(TYPEDSIGNATURES)

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

$(TYPEDSIGNATURES)

That is we don't know if the first entries (trades) of the array, normalized to the respective candle timestamp, was *all*
the trades for that particular candle.
"
function startdateidx(v::AbstractVector, tf::TimeFrame)
    from_date = apply(tf, first(v).timestamp) + tf.period
    i = findfirst(x -> x.timestamp >= from_date, @view(v[(begin+1):end]))
    isnothing(i) ? lastindex(v) : i + 1
end

@doc "A constant array defining the column names for trade data, including timestamp, price, and amount."
const TRADES_COLS = [:timestamp, :price, :amount]
@doc """Converts a DataFrame to OHLCV format.

$(TYPEDSIGNATURES)

This function takes a DataFrame `df` and converts it to Open, High, Low, Close, Volume (OHLCV) format.

"""
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

@doc """Transforms a vector of trade data (with 'timestamp', 'price', and 'amount' fields) into the OHLCV format.

$(TYPEDSIGNATURES)

tf: The desired timeframe for the OHLCV data. Default is 1m (one minute). trim_left: If true, skips the first candle in the data. Default is true. trim_right: If true, skips the most recent candle if it is too close to the current time relative to the timeframe. Default is true.

The function returns a tuple (;ohlcv, start, stop). 'ohlcv' is the transformed data, 'start' and 'stop' denote the range of the input vector used. If no candles could be built, the function returns nothing.
"""
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
