@doc """ Module for aligning data frames.

This module provides functionality for aligning data frames in time, useful for synchronizing time-series data across different sources.
"""
module Alignments
using ..Misc
using ..Misc.TimeTicks
using ..Misc.Lang
using ..Misc.DocStringExtensions
using Data.DataStructures
using Data.DataFrames
using Data: PairData, @with
using Data.DFUtils: copysubs!

timestamp_by_timeframe(df, tf, tail) = apply(tf, df[tail ? end : begin, :timestamp])

function common_timestamp(
    dfs::AbstractArray{DataFrame}, tf::TimeFrame, common=nothing, tail=false
)
    isnothing(common) && (common = timestamp_by_timeframe(dfs[1], tf, tail))
    compare = tail ? (<) : (>)
    for df in dfs[2:end]
        let ts = timestamp_by_timeframe(df, tf, tail)
            # this dataframe data starts later than our current initial
            # our common will now become the oldest timestamp of this dataframe
            compare(ts, common) && (common = ts)
        end
    end
    common
end

is_left_adjacent(target, step) = x -> x + step > target
is_right_adjacent(target, step) = x -> x - step < target           # right - step <= left

function trim_to!(df::AbstractDataFrame, to, tf, tail=false)
    if tail
        f = is_right_adjacent(to, tf.period)
        rev_idx = @something findfirst(f, @view(df.timestamp[end:-1:1])) 1
        start = size(df)[1] - rev_idx + 1
        idx = start:size(df)[1]
        # @show rev_idx, idx, size(df), df.timestamp[end], to
    else
        f = is_left_adjacent(to, tf.period)
        stop = @something(findfirst(f, df.timestamp), 1) - 1
        idx = 1:stop
    end
    if length(idx) > 0
        copysubs!(df) # Necessary to replace subarrays which are read-only
        deleteat!(df, idx)
    end
end

function _trim_1(data::AbstractDict{K,V}, tail::Bool) where {K,V}
    common = nothing
    for (tf, ohlcvs) in data
        common = common_timestamp(ohlcvs, tf, common, tail)
    end
    # After we have found the common timestamp, trim the dataframes
    foreach(data) do (tf, dfs)
        foreach(dfs) do df
            trim_to!(df, common, tf, tail)
        end
    end
end

@doc """ Trims the data to start from the same timestamp.

$(TYPEDSIGNATURES)

This function ensures that all the data frames in the given AbstractDict start from the same timestamp, with an option to also trim the end.
"""
function trim!(data::AbstractDict; tail=false)
    @ifdebug @assert begin
        (bigger_tf, bigger_ohlcv) = last(data)
        all(
            begin
                (x -> x == apply(bigger_tf, x))(ohlcv[1, :timestamp])
            end for ohlcv in bigger_ohlcv
        )
    end
    _trim_1(data, false)
    tail && _trim_1(data, true)
    nothing
end

@doc """Checks the alignment of data in a dictionary.

$(TYPEDSIGNATURES)

This function takes a dictionary `data` and optionally a boolean `raise`. It checks if all the data arrays in `data` are aligned (i.e., have the same length). If `raise` is true, it throws an error if the data arrays are not aligned.

"""
function check_alignment(data::AbstractDict; raise=false)
    first_ts = first(data)[2][1][begin, :timestamp]
    last_ts = first(data)[2][1][end, :timestamp]
    for (tf, dfs) in data
        check = all(
            df[begin, :timestamp] == first_ts && df[end, :timestamp] == last_ts for
            df in dfs
        )
        if !check
            raise && throw(AssertionError("Wrong alignment for data at timeframe $tf."))
            return false
        end
    end
    return true
end

@doc """Trims pairs data in a dictionary from a specified index.

$(TYPEDSIGNATURES)

This function takes a dictionary `data` of PairData and an integer `from`. It trims the pairs data in `data` from the specified index `from`.

"""
function trim_pairs_data(data::AbstractDict{String,PairData}, from::Int)
    for (_, p) in data
        tmp = copy(p.data)
        select!(p.data, [])
        if from >= 0
            idx = max(size(tmp, 1), from)
            @with tmp begin
                for col in eachcol(tmp)
                    p.data[!, col] = @view col[begin:(idx - 1)]
                end
            end
        else
            idx = size(tmp, 1) + from
            if idx > 0
                @with tmp begin
                    for (col, name) in zip(eachcol(tmp), names(tmp))
                        p.data[!, name] = @view col[(idx + 1):end]
                    end
                end
            end
        end
    end
end

export trim!, check_alignment

end
