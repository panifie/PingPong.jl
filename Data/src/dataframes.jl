@doc "Utilities for DataFrames.jl, prominently timeframe based indexing."
module DFUtils
using DataFrames
using DataFrames: index
using ..TimeTicks
import ..TimeTicks: TimeTicks, timeframe, timeframe!
import Misc: after, before
using Misc.DocStringExtensions
using ..Lang
import Base: getindex
import ..Data: contiguous_ts

@doc "Get the column names for dataframe as symbols.

$(TYPEDSIGNATURES)
"
colnames(df::AbstractDataFrame) = index(df).names

@doc "Get the first timestamp in the dataframe (:timestamp column)."
firstdate(df::D) where {D<:AbstractDataFrame} = df.timestamp[begin]
@doc "Get the last timestamp in the dataframe (:timestamp column)."
lastdate(df::D) where {D<:AbstractDataFrame} = df.timestamp[end]
@doc "The zeroed row of a dataframe (`zero(el)` from every column)."
function zerorow(df::D; skip_cols=()) where {D<:AbstractDataFrame}
    let cn = ((col for col in colnames(df) if col ∉ skip_cols)...,)
        NamedTuple{cn}(zero(eltype(getproperty(df, col))) for col in cn)
    end
end

@doc """Returns the timeframe of a dataframe according to its metadata.

$(TYPEDSIGNATURES)

If the value is not found in the metadata, infer it by `timestamp` column of the dataframe.
If the timeframe can't be inferred, a `TimeFrame(0)` is returned.
NOTE: slow func, for speed use [`timeframe!(::DataFrame)`](@ref)"""
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
@doc "Sets the dataframe's timeframe metadata to the given `TimeFrame`.

Shouldn't be called directly, see [`timeframe!(::DataFrame)`](@ref)"
function timeframe!(df::D, t::T) where {D<:AbstractDataFrame,T<:TimeFrame}
    colmetadata!(df, :timestamp, "timeframe", t; style=:note)
    t
end
@doc "Infer the dataframe's timeframe from the `timestamp` column of the dataframe and sets it."
function timeframe!(df::D) where {D<:AbstractDataFrame}
    @something colmetadata(df, :timestamp, "timeframe", nothing) begin
        tf = @infertf(df)
        colmetadata!(df, :timestamp, "timeframe", tf; style=:note)
        tf
    end
end
@doc "Forcefully infers the dataframe timeframe. See [`timeframe!(::DataFrame)`](@ref)"
timeframe!!(df::D) where {D<:AbstractDataFrame} = begin
    tf = @infertf(df)
    timeframe!(df, tf)
    tf
end

@doc "Get the position of date in the `:timestamp` column of the dataframe.

$(TYPEDSIGNATURES)"
function dateindex(df::D, date::DateTime) where {D<:AbstractDataFrame}
    searchsortedlast(df.timestamp, date)
end

@doc "Get the position of date in the `:timestamp` column of the dataframe based on timeframe arithmentics.

$(TYPEDSIGNATURES)"
function dateindex(df::D, date::DateTime, ::Val{:timeframe}) where {D<:AbstractDataFrame}
    (date - firstdate(df)) ÷ timeframe(df).period + 1
end

# TODO: move dateindex to TimeTicks
@doc "Same as [`dateindex`](@ref)"
function dateindex(v::V, date::DateTime) where {V<:AbstractVector}
    searchsortedlast(v, date)
end

@doc "Same [`dateindex(::AbstractVector, ::DateTime)`](@ref) but always returns the first index if the index is not found in the vector."
function dateindex(v::V, date::DateTime, ::Val{:nonzero}) where {V<:AbstractVector}
    idx = dateindex(v, date)
    if iszero(idx)
        firstindex(v)
    else
        idx
    end
end

@doc "Same [`dateindex(::AbstractDataFrame, ::DateTime)`](@ref) but always returns the first index if the index is not found in the vector."
function dateindex(df::AbstractDataFrame, date::DateTime, ::Val{:nonzero})
    dateindex(df.timestamp, date, Val(:nonzero))
end
dateindex(v, date, sym::Symbol) = dateindex(v, date, Val(sym))

valueorview(df::DataFrame, idx, col::String) = getproperty(df, col)[idx]
valueorview(df::DataFrame, idx, col::Symbol) = getproperty(df, col)[idx]
valueorview(df::DataFrame, idx, cols) = @view df[idx, cols]
# NOTE: We should subtype an abstract dataframe...arr
function getindex(df::D, idx::DateTime, cols) where {D<:AbstractDataFrame}
    v = valueorview(df, searchsortedlast(df.timestamp, idx), cols)
    @ifdebug @assert v == getdate(df, idx, cols)
    v
end

@doc """Get the specified columns based on given date (used as index).

$(TYPEDSIGNATURES)

While indexing ohlcv data we have to consider the *time of arrival* of a candle.
In general candles collect the price *up to* its timestamp.
E.g. the candle at time `2000-01-01` would have tracked time from `1999-12-31T00:00:00` to `2000-01-01T00:00:00`.
Therefore what we return is always the *left adjacent* timestamp of the queried one.
"""
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

@doc """Get the date-based subset of a DataFrame.

$(TYPEDSIGNATURES)

Indexing by date ranges allows to query ohlcv using the timestamp column as index, assuming that the data has no missing values and is already sorted.

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

@doc """Get the date range of a DataFrame.

$(TYPEDSIGNATURES)

Used to get the date range of a DataFrame `df`. It takes in the DataFrame `df`, an optional timeframe `tf` (default is the current timeframe of the DataFrame), and an optional `rightofs` parameter.
The `rightofs` parameter specifies the number of steps to shift the date range to the right. For example, if `rightofs` is set to 1, the date range will be shifted one step to the right. This can be useful for calculating future date ranges based on the current date range.
Returns the date range of the DataFrame `df` based on the specified timeframe `tf` and `rightofs` parameter.
"""
function daterange(df::D, tf=timeframe(df), rightofs=1) where {D<:AbstractDataFrame}
    DateRange(df.timestamp[begin], df.timestamp[end] + tf * rightofs, tf)
end

_copysub(arr::A) where {A<:Array} = arr
_copysub(arr::A) where {A<:SubArray} = Array(arr)

@doc "Replaces subarrays with arrays.

$(TYPEDSIGNATURES)"
function copysubs!(
    df::D, copyfunc=_copysub, elsefunc=Returns(nothing)
) where {D<:AbstractDataFrame}
    i = 1
    mask = Vector{Bool}(undef, ncol(df))
    for col in eachcol(df)
        if (mask[i] = col isa SubArray)
            df[!, i] = copyfunc(col)
        else
            elsefunc(col)
        end
        i += 1
    end
    mask
end

function _make_room(df, capacity, n)
    if n < 0
        throw(ArgumentError("n must be non-negative"))
    end
    if capacity < 0
        throw(ArgumentError("capacity must be non-negative"))
    end
    current_rows = nrow(df)
    # Ensure we only delete rows if appending `n` more rows would exceed `capacity`
    if current_rows + n > capacity
        copysubs!(df)
        rows_to_remove = current_rows + n - capacity
        # Ensure we do not attempt to delete more rows than exist
        if rows_to_remove > current_rows
            empty!(df)
        else
            # Delete rows from the beginning of the dataframe
            deleteat!(df, 1:rows_to_remove)
        end
    end
end

@doc "Mutates `v` to `df` ensuring the dataframe never grows larger than `maxlen`.

$(TYPEDSIGNATURES)
"
function _mutatemax!(df, v, maxlen, n, mut; cols=:union)
    _make_room(df, maxlen, n)
    mut(df, v; cols)
    @ifdebug @assert nrow(df) <= maxlen
end

function _tomaxlen(v, maxlen)
    li = lastindex(v, 1)
    from = li - min(maxlen, li) + 1
    view(v, from:li, :)
end

@doc "See [`_mutatemax!`](@ref)"
function appendmax!(df, v, maxlen; cols=:union)
    _mutatemax!(df, _tomaxlen(v, maxlen), maxlen, size(v, 1), append!; cols)
end
@doc "See [`_mutatemax!`](@ref)"
function prependmax!(df, v, maxlen; cols=:union)
    _mutatemax!(df, _tomaxlen(v, maxlen), maxlen, size(v, 1), prepend!; cols)
end
@doc "See [`_mutatemax!`](@ref)"
pushmax!(df, v, maxlen; cols=:union) = _mutatemax!(df, v, maxlen, 1, push!; cols)

function contiguous_ts(df::DataFrame, args...; kwargs...)
    contiguous_ts(df.timestamp, string(timeframe!(df)), args...; kwargs...)
end

@doc """Get the subset of a DataFrame containing rows after a specific date.

$(TYPEDSIGNATURES)

This function is used to get the subset of a DataFrame `df` that contains rows after a specific date `dt`. It takes in the DataFrame `df`, the specific date `dt` as a `DateTime` object, and optional columns `cols` to include in the subset.
If `cols` is not specified, the function includes all columns in the subset. If `cols` is specified, only the columns listed in `cols` will be included in the subset.
This function returns a `DataFrameView` that contains only the rows of `df` that occur after the specified date `dt` and the specified columns `cols`.
"""
function after(df::DataFrame, dt::DateTime, cols=:)
    idx = dateindex(df, dt) + 1
    view(df, idx:nrow(df), cols)
end

@doc "Complement of [`after`](@ref)"
function before(df::DataFrame, dt::DateTime, cols=:)
    idx = dateindex(df, dt) - 1
    view(df, 1:idx, cols)
end

@doc "Inserts rows in `src` to `dst`, zeroing columns not present in `dst`.

$(TYPEDSIGNATURES)
"
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

_fromidx(from::Integer, offset::Integer) = from + offset
_fromidx(from::Integer, offset) = from + round(Int, offset, RoundUp)

@doc """Create a view of an OHLCV DataFrame starting from a specific index.

$(TYPEDSIGNATURES)

Used to create a view of an OHLCV DataFrame `ohlcv` starting from a specific index `from`. It takes in the OHLCV DataFrame `ohlcv`, the starting index `from` as an integer, and optional parameters `offset` and `cols`.
The `offset` parameter specifies the number of rows to offset the view from the starting index. The default value is 0, indicating no offset.
The `cols` parameter specifies the columns to include in the view. By default, all columns are included.
Returns a view of the original OHLCV DataFrame `ohlcv` starting from the specified index `from`, with an optional offset and specified columns.
"""
function viewfrom(ohlcv, from::Integer; offset=0, cols=Colon())
    @view ohlcv[max(1, _fromidx(from, offset)):end, cols]
end

function viewfrom(ohlcv, from::DateTime; kwargs...)
    idx = dateindex(ohlcv, from)
    viewfrom(ohlcv, idx; kwargs...)
end

function viewfrom(ohlcv, ::Nothing; kwargs...)
    ohlcv
end

@doc """Set the values of specific columns in one DataFrame from another DataFrame.

$(TYPEDSIGNATURES)

Used to set the values of specific columns in one DataFrame `dst` from another DataFrame `src`. It takes in the destination DataFrame `dst`, the source DataFrame `src`, the columns to set `cols`, and optional indices `idx` to specify the rows to set.
The `cols` parameter specifies the columns in the destination DataFrame `dst` that will be set with the corresponding values from the source DataFrame `src`.
The `idx` parameter specifies the indices of the rows in the destination DataFrame `dst` that will be set. By default, it sets all rows.
It mutates the destination DataFrame `dst` by setting the values of the specified columns `cols` with the corresponding values from the source DataFrame `src`.
"""
function setcols!(dst, src, cols, idx=firstindex(dst, 1):lastindex(dst, 1))
    data_type = eltype(src)
    for (n, col) in enumerate(cols)
        if !hasproperty(dst, col)
            dst[!, col] = Vector{data_type}(1:size(dst, 1))
        end
        dst[idx, col] = @view src[:, n]
    end
end

export firstdate, lastdate, dateindex, daterange, viewfrom
export colnames, getdate, zerorow, addcols!, setcols!

end
