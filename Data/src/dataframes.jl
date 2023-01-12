@doc "Utilities for DataFrames.jl, prominently timeframe based indexing."
module DFUtils
using Dates: AbstractDateTime
using Dates
using DataFrames
using TimeTicks
import Base: getindex

@inline firstdate(df::T where {T<:AbstractDataFrame}) = df.timestamp[begin]
@inline lastdate(df::T where {T<:AbstractDataFrame}) = df.timestamp[end]

timeframe(df::T where {T<:AbstractDataFrame})::F where {F<:TimeFrame} = begin
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
@inline timeframe!(df::T, t::F) where {T<:AbstractDataFrame,F<:TimeFrame} =
    colmetadata!(df, :timestamp, "timeframe", t)
@inline timeframe!(df::T where {T<:AbstractDataFrame}) = begin
    timeframe!(df, @infertf(df))
end


@doc "Get the position of date in the `:timestamp` column of the dataframe."
dateindex(df::T where {T<:AbstractDataFrame}, date::DateTime) = begin
    (date - firstdate(df)) ÷ timeframe(df).period + 1
end

# NOTE: We should subtype an abstract dataframe...arr
@doc "While indexing ohlcv data we have to consider the *time of arrival* of a candle. In general candles collect the price *up to* its timestamp. E.g. the candle at time `2000-01-01` would have tracked time from `1999-12-31T00:00:00` to `2000-01-01T00:00:00`. Therefore what we return is always the *left adjacent* timestamp of the queried one."
getindex(df::T where {T<:AbstractDataFrame}, idx::DateTime, cols) = begin
    tf = timeframe(df)
    @debug @assert @infertf(df) == tf
    start = firstdate(df)
    start <= idx || throw(ArgumentError("$idx not found in dataframe."))
    int_idx = (idx - start) ÷ tf.period + 1
    int_idx > size(df)[1] && throw(ArgumentError("$idx not found in dataframe."))
    @debug @assert df.timestamp[int_idx] == idx
    @view df[int_idx, cols]
end

@doc """Indexing by date ranges allows to query ohlcv using the timestamp column as index, assuming that the data has no missing values and is already sorted.

Examples:
df[dtr"1999-.."] # Starting from 1999 up to the end
df[dtr"..1999-"] # From the beginning up to 1999
df[dtr"1999-..2000-"] # The Year 1999
"""
getindex(df::T where {T<:AbstractDataFrame}, dr::DateRange, cols) = begin
    tf = timeframe(df)
    @debug @assert @infertf(df) == tf
    start = firstdate(df)
    stop = lastdate(df)
    if (!isnothing(dr.start) && dr.start < start) || (!isnothing(dr.stop) && dr.stop > stop)
        throw(
            ArgumentError(
                "Dates ($(dr.start) : $(dr.stop)) out of range for dataframe ($start : $stop).",
            ),
        )
    end
    # arithmetic indexing although slower for smaller arrays, has complexity O(1)ish
    start_idx = if isnothing(dr.start)
        firstindex(df.timestamp)
    else
        (dr.start - start) ÷ tf.period + 1
    end
    stop_idx = if isnothing(dr.stop)
        lastindex(df.timestamp)
    else
        start_idx + (dr.stop - dr.start) ÷ tf.period
    end
    # start_idx = searchsortedfirst(df.timestamp, dr.start)
    # stop_idx = start_idx + searchsortedfirst(@view(df.timestamp[start_idx+1:end]), dr.stop)
    @debug @assert df.timestamp[start_idx] == dr.start && df.timestamp[stop_idx] == dr.stop
    @view df[start_idx:stop_idx, cols]
end

getindex(df::T where {T<:AbstractDataFrame}, idx::DateTime) =
    getindex(df, idx, Symbol.(names(df)))
getindex(df::T where {T<:AbstractDataFrame}, idx::DateRange) =
    getindex(df, idx, Symbol.(names(df)))

function daterange(df::T where {T<:AbstractDataFrame})
    DateRange(df.timestamp[begin], df.timestamp[end], timeframe(df))
end

export firstdate, lastdate, timeframe, timeframe!, getindex, dateindex, daterange

end
