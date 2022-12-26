@doc "Utilities for DataFrames.jl, prominently timeframe based indexing."
module DFUtils
using Dates
using DataFrames
using TimeTicks
import Base: getindex

firstdate(df::DataFrame) = df.timestamp[begin]
lastdate(df::DataFrame) = df.timestamp[end]

timeframe(df::DataFrame)::TimeFrame = begin
    try
        colmetadata(df, :timestamp, "timeframe")
    catch error
        if error isa ArgumentError
            timeframe!(df)
            timeframe(df)
        else
            rethrow(error)
        end
    end
end
timeframe!(df::DataFrame, t::TimeFrame) = colmetadata!(df, :timestamp, "timeframe", t)
timeframe!(df::DataFrame) = timeframe!(df, @infertf(df))

# NOTE: We should subtype an abstract dataframe...arr
@doc "While indexing ohlcv data we have to consider the *time of arrival* of a candle. In general candles collect the price *up to* its timestamp. E.g. the candle at time `2000-01-01` would have tracked time from `1999-12-31T00:00:00` to `2000-01-01T00:00:00`. Therefore what we return is always the *left adjacent* timestamp of the queried one."
getindex(df::DataFrame, idx::DateTime, cols) = begin
    tf = timeframe(df)
    @debug @assert @infertf(df) == tf
    start = firstdate(df)
    stop = lastdate(df)
    start <= idx <= stop || throw(ArgumentError("$idx not found in dataframe."))
    int_idx = (idx - start) ÷ tf.period + 1
    @debug @assert df.timestamp[int_idx] == idx
    @view df[int_idx, cols]
end

@doc """Indexing by date ranges allows to query ohlcv using the timestamp column as index, assuming that the data has no missing values and is already sorted.

Examples:
df[dtr"1999-.."] # Starting from 1999 up to the end
df[dtr"..1999-"] # From the beginning up to 1999
df[dtr"1999-..2000-"] # The Year 1999
"""
getindex(df::DataFrame, dr::DateRange, cols) = begin
    tf = timeframe(df)
    @debug @assert @infertf(df) == tf
    start = firstdate(df)
    stop = lastdate(df)
    if (!isnothing(dr.start) && dr.start < start) ||
       (!isnothing(dr.stop) && dr.stop > stop)
        throw(ArgumentError("Dates ($(dr.start) : $(dr.stop)) out of range for dataframe ($start : $stop)."))
    end
    # arithmetic indexing although slower for smaller arrays, has complexity O(1)ish
    start_idx = isnothing(dr.start) ? firstindex(df.timestamp) :
                (dr.start - start) ÷ tf.period + 1
    stop_idx = isnothing(dr.stop) ? lastindex(df.timestamp) :
               start_idx + (dr.stop - dr.start) ÷ tf.period
    # start_idx = searchsortedfirst(df.timestamp, dr.start)
    # stop_idx = start_idx + searchsortedfirst(@view(df.timestamp[start_idx+1:end]), dr.stop)
    @debug @assert df.timestamp[start_idx] == dr.start && df.timestamp[stop_idx] == dr.stop
    @view df[start_idx:stop_idx, cols]
end

getindex(df::DataFrame, idx::DateTime) = getindex(df, idx, Symbol.(names(df)))
getindex(df::DataFrame, idx::DateRange) = getindex(df, idx, Symbol.(names(df)))

export firstdate, lastdate, timeframe, timeframe!

end
