@doc "Utilities for DataFrames.jl, prominently timeframe based indexing."
module DFUtils
using DataFrames
using DataFrames: index
using TimeTicks
using Lang
import Base: getindex
import TimeTicks: timeframe, timeframe!

@doc "Get the column names for dataframe as symbols."
colnames(df::AbstractDataFrame) = index(df).names

firstdate(df::AbstractDataFrame) = df.timestamp[begin]
lastdate(df::AbstractDataFrame) = df.timestamp[end]

@doc "Returns the timeframe of a dataframe according to its metadata.
If the value is not found in the metadata, infer it by `timestamp` column of the dataframe.
If the timeframe can't be inferred, a `TimeFrame(0)` is returned. "
function timeframe(df::AbstractDataFrame)::TimeFrame
    if hasproperty(df, :timestamp)
        md = @lget!(colmetadata(df), :timestamp, Dict{String,Any}())
        @something get(md, "timeframe", nothing) begin
            if size(df, 1) > 0
                timeframe!(df)
            else
                TimeFrame(Second(0))
            end
        end
    end
end
function timeframe!(df::AbstractDataFrame, t::TimeFrame)
    colmetadata!(df, :timestamp, "timeframe", t)
    t
end
function timeframe!(df::AbstractDataFrame)
    @something colmetadata(df, :timestamp, "timeframe", nothing) begin
        tf = @infertf(df)
        colmetadata!(df, :timestamp, "timeframe", tf)
        tf
    end
end
timeframe!!(df::AbstractDataFrame) = begin
    tf = @infertf(df)
    timeframe!(df, tf)
    tf
end

@doc "Get the position of date in the `:timestamp` column of the dataframe."
function dateindex(df::AbstractDataFrame, date::DateTime)
    (date - firstdate(df)) ÷ timeframe(df).period + 1
end

valueorview(df::DataFrame, idx, col::String) = getproperty(df, col)[idx]
valueorview(df::DataFrame, idx, col::Symbol) = getproperty(df, col)[idx]
valueorview(df::DataFrame, idx, cols) = @view df[idx, cols]
# NOTE: We should subtype an abstract dataframe...arr
function getindex(df::AbstractDataFrame, idx::DateTime, cols)
    v = valueorview(df, searchsortedlast(df.timestamp, idx), cols)
    @ifdebug @assert v == getdate(df, idx, cols)
    v
end

@doc """While indexing ohlcv data we have to consider the *time of arrival* of a candle.
In general candles collect the price *up to* its timestamp.
E.g. the candle at time `2000-01-01` would have tracked time from `1999-12-31T00:00:00` to `2000-01-01T00:00:00`.
Therefore what we return is always the *left adjacent* timestamp of the queried one."""
function getdate(df::AbstractDataFrame, idx::DateTime, cols, tf::TimeFrame=timeframe!(df))
    @ifdebug @assert @infertf(df) == tf
    start = firstdate(df)
    # start = df.timestamp[begin]
    start <= idx || throw(ArgumentError("$idx not found in dataframe."))
    int_idx = (idx - start) ÷ tf.period + 1
    int_idx > size(df)[1] && throw(ArgumentError("$idx not found in dataframe."))
    @ifdebug @assert df.timestamp[int_idx] == idx
    valueorview(df, int_idx, cols)
end

@doc """Indexing by date ranges allows to query ohlcv using the timestamp column as index, assuming that the data has no missing values and is already sorted.

Examples:
df[dtr"1999-.."] # Starting from 1999 up to the end
df[dtr"..1999-"] # From the beginning up to 1999
df[dtr"1999-..2000-"] # The Year 1999
"""
function getdate(df::AbstractDataFrame, dr::DateRange, cols, tf=timeframe!(df))
    @ifdebug @assert @infertf(df) == tf
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
    @ifdebug @assert df.timestamp[start_idx] == dr.start &&
        df.timestamp[stop_idx] == dr.stop
    @view df[start_idx:stop_idx, cols]
end

function getindex(df::AbstractDataFrame, dr::DateRange, cols)
    start_idx = searchsortedfirst(df.timestamp, dr.start)
    stop_idx = searchsortedlast(df.timestamp, dr.stop)
    v = @view df[start_idx:stop_idx, cols]
    @ifdebug @assert v == getdate(df, dr, cols)
    v
end

function getindex(df::AbstractDataFrame, idx::DateTime)
    getindex(df, idx, Symbol.(names(df)))
end
function getindex(df::AbstractDataFrame, idx::DateRange)
    getindex(df, idx, Symbol.(names(df)))
end

function daterange(df::AbstractDataFrame)
    DateRange(df.timestamp[begin], df.timestamp[end], timeframe(df))
end

function _make_room(df, capacity, n)
    # @ifdebug @assert n > 0;
    diff = capacity - nrow(df)
    if diff < n
        deleteat!(df, firstindex(df, 1):abs(diff - n))
    end
end

@doc "Mutates `v` to `df` ensuring the dataframe never grows larger than `maxlen`."
function _mutatemax!(df, v, maxlen, n, mut)
    _make_room(df, maxlen, n)
    mut(df, v)
    @ifdebug @assert nrow(df) <= maxlen
end

function _tomaxlen(v, maxlen)
    li = lastindex(v, 1)
    from = li - min(maxlen, li) + 1
    view(v, from:li, :)
end

@doc "See `_mutatemax!`"
function appendmax!(df, v, maxlen)
    _mutatemax!(df, _tomaxlen(v, maxlen), maxlen, size(v, 1), append!)
end
@doc "See `_mutatemax!`"
function prependmax!(df, v, maxlen)
    _mutatemax!(df, _tomaxlen(v, maxlen), maxlen, size(v, 1), prepend!)
end
@doc "See `_mutatemax!`"
pushmax!(df, v, maxlen) = _mutatemax!(df, v, maxlen, 1, push!)

export firstdate, lastdate, getindex, dateindex, daterange, colnames, getdate

end
