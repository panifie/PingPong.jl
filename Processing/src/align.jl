module Alignments
using TimeTicks
using Lang
using Misc
using Data.DataStructures
using Data.DataFrames
using Data: PairData, @with

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

_copysub(arr::Array) = arr
_copysub(arr::SubArray) = Array(arr)

@doc "Replaces subarrays with arrays."
copysubs!(df::AbstractDataFrame) = begin
    for col in Symbol.(names(df))
        arr = getproperty(df, col)
        setproperty!(df, col, _copysub(arr))
    end
end

is_left_adjacent(target, step) = x -> x + step > target
is_right_adjacent(target, step) = x -> x - step < target           # right - step <= left

function trim_to!(df::AbstractDataFrame, to, tf, tail=false)
    if tail
        f = is_right_adjacent(to, tf.period)
        rev_idx = findfirst(f, @view(df.timestamp[end:-1:1]))
        start = size(df)[1] - rev_idx + 1
        idx = start:size(df)[1]
        # @show rev_idx, idx, size(df), df.timestamp[end], to
    else
        f = is_left_adjacent(to, tf.period)
        stop = findfirst(f, df.timestamp) - 1
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
    for (tf, dfs) in data
        trim_to!.(dfs, common, tf, tail)
    end
end

@doc "Ensures all the ohlcv frames start from the same timestamp.
tail: also trims the end."
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
