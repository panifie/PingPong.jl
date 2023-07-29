@doc "Utilities for DataFrames.jl, prominently timeframe based indexing."
module DFUtils
using DataFrames
using DataFrames: index
using TimeTicks
import TimeTicks: timeframe, timeframe!
import Misc: after, before
using Lang
import Base: getindex
import ..Data: contiguous_ts

@doc "Get the column names for dataframe as symbols."
colnames(df::AbstractDataFrame) = index(df).names

firstdate(df::D) where {D<:AbstractDataFrame} = df.timestamp[begin]
lastdate(df::D) where {D<:AbstractDataFrame} = df.timestamp[end]
function zerorow(df::D; skip_cols=()) where {D<:AbstractDataFrame}
    let cn = ((col for col in colnames(df) if col ∉ skip_cols)...,)
        NamedTuple{cn}(zero(eltype(getproperty(df, col))) for col in cn)
    end
end

@doc "Returns the timeframe of a dataframe according to its metadata.
If the value is not found in the metadata, infer it by `timestamp` column of the dataframe.
If the timeframe can't be inferred, a `TimeFrame(0)` is returned. "
function timeframe(df::D)::TimeFrame where {D<:AbstractDataFrame}
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
function timeframe!(df::D, t::T) where {D<:AbstractDataFrame,T<:TimeFrame}
    colmetadata!(df, :timestamp, "timeframe", t; style=:note)
    t
end
function timeframe!(df::D) where {D<:AbstractDataFrame}
    @something colmetadata(df, :timestamp, "timeframe", nothing) begin
        tf = @infertf(df)
        colmetadata!(df, :timestamp, "timeframe", tf; style=:note)
        tf
    end
end
timeframe!!(df::D) where {D<:AbstractDataFrame} = begin
    tf = @infertf(df)
    timeframe!(df, tf)
    tf
end

@doc "Get the position of date in the `:timestamp` column of the dataframe."
function dateindex(df::D, date::DateTime) where {D<:AbstractDataFrame}
    searchsortedlast(df.timestamp, date)
end

@doc "Get the position of date in the `:timestamp` column of the dataframe."
function dateindex(df::D, date::DateTime, ::Val{:timeframe}) where {D<:AbstractDataFrame}
    (date - firstdate(df)) ÷ timeframe(df).period + 1
end

# TODO: move dateindex to TimeTicks
function dateindex(v::V, date::DateTime) where {V<:AbstractVector}
    searchsortedlast(v, date)
end

valueorview(df::DataFrame, idx, col::String) = getproperty(df, col)[idx]
valueorview(df::DataFrame, idx, col::Symbol) = getproperty(df, col)[idx]
valueorview(df::DataFrame, idx, cols) = @view df[idx, cols]
# NOTE: We should subtype an abstract dataframe...arr
function getindex(df::D, idx::DateTime, cols) where {D<:AbstractDataFrame}
    v = valueorview(df, searchsortedlast(df.timestamp, idx), cols)
    @ifdebug @assert v == getdate(df, idx, cols)
    v
end

@doc """While indexing ohlcv data we have to consider the *time of arrival* of a candle.
In general candles collect the price *up to* its timestamp.
E.g. the candle at time `2000-01-01` would have tracked time from `1999-12-31T00:00:00` to `2000-01-01T00:00:00`.
Therefore what we return is always the *left adjacent* timestamp of the queried one."""
function getdate(
    df::D, idx::DateTime, cols, tf::T=timeframe!(df)
) where {D<:AbstractDataFrame,T<:TimeFrame}
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
function getdate(
    df::D, dr::Union{DateRange,StepRange{DateTime,<:Period}}, cols, tf=timeframe!(df)
) where {D<:AbstractDataFrame}
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

function getindex(
    df::D, dr::Union{DateRange,StepRange{DateTime,<:Period}}, cols
) where {D<:AbstractDataFrame}
    start_idx = searchsortedfirst(df.timestamp, dr.start)
    stop_idx = searchsortedlast(df.timestamp, dr.stop)
    v = @view df[start_idx:stop_idx, cols]
    @ifdebug @assert v == getdate(df, dr, cols)
    v
end

function getindex(df::D, idx::DateTime) where {D<:AbstractDataFrame}
    getindex(df, idx, Symbol.(names(df)))
end
function getindex(
    df::D, idx::Union{DateRange,StepRange{DateTime,<:Period}}
) where {D<:AbstractDataFrame}
    getindex(df, idx, Symbol.(names(df)))
end

function daterange(df::D, tf=timeframe(df), rightofs=1) where {D<:AbstractDataFrame}
    DateRange(df.timestamp[begin], df.timestamp[end] + tf * rightofs, tf)
end

_copysub(arr::A) where {A<:Array} = arr
_copysub(arr::A) where {A<:SubArray} = Array(arr)

@doc "Replaces subarrays with arrays."
function copysubs!(df::D, copyfunc=_copysub) where {D<:AbstractDataFrame}
    subs_mask = [x isa SubArray for x in eachcol(df)]
    if any(subs_mask)
        subs = @view df[:, subs_mask]
        for p in propertynames(subs)
            df[!, p] = _copysub(getproperty(subs, p))
        end
    end
end

function _make_room(df, capacity, n)
    diff = capacity - nrow(df)
    copysubs!(df)
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

function contiguous_ts(df::DataFrame, args...; kwargs...)
    contiguous_ts(df.timestamp, string(timeframe!(df)), args...; kwargs...)
end

function after(df::DataFrame, dt::DateTime, cols=:)
    idx = dateindex(df, dt) + 1
    view(df, idx:nrow(df), cols)
end

function before(df::DataFrame, dt::DateTime, cols=:)
    idx = dateindex(df, dt) - 1
    view(df, 1:idx, cols)
end

@doc "Append rows in df2 to df1, zeroing columns not present in df2."
function addcols!(dst, src)
    src_cols = Set(colnames(src))
    dst_cols = colnames(dst)
    n = nrow(dst)
    for col in src_cols
        if col ∉ dst_cols
            dst[!, col] = similar(getproperty(src, col), n)
        end
    end
end

export firstdate, lastdate, getindex, dateindex, daterange, colnames, getdate, zerorow

end
