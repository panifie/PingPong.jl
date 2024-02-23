using Data.DataStructures: SortedDict
using Data: contiguous_ts
using Data.DFUtils: addcols!
using .Lang: @deassert
using .Misc.DocStringExtensions
using .Misc: rangeafter
import Data: propagate_ohlcv!

@doc """Updates OHLCV data across multiple time frames.

$(TYPEDSIGNATURES)

This function takes a dictionary `data` and an aggregation function `update_func`. It updates the OHLCV data from the base time frame to the higher time frames in `data`, using `update_func` to aggregate the OHLCV values from the base to the target time frame.
The function modifies `data` in place and returns it.
If the base time frame data frame in `data` is empty, the function clears all the higher time frames data frames.
Otherwise, it asynchronously updates each higher time frame data frame and ensures that the timestamps are synchronized across all time frames.

"""
function propagate_ohlcv!(
    data::SortedDict{TimeFrame,DataFrame}, update_func::Function=propagate_ohlcv!
)
    base_tf, base_data = first(data)
    if isempty(base_data)
        foreach(empty!, Iterators.drop(values(data), 1))
        return data
    else
        props_itr = Iterators.drop(data, 1)
        props_n = length(props_itr)
        for (dst_tf, dst_data) in props_itr
            let src_data = base_data, src_tf = base_tf, tf_idx = 1
                function dowarn()
                    @debug "propagate ohlcv: failed" base_tf src_tf dst_tf
                end
                while true
                    if tf_idx > props_n
                        break
                    end
                    # use a lower res frame if the upper res frame has not enough candles
                    if nrow(src_data) < count(src_tf, dst_tf)
                        src_tf, src_data = first(Iterators.drop(data, tf_idx))
                        # Can't propagate if the source tf exceedes the target tf
                        if src_tf >= dst_tf
                            dowarn()
                            break
                        end
                        tf_idx += 1
                        continue
                    end
                    update_func(src_tf, src_data, dst_tf, dst_data)
                    # stop if dst data matches the padded date of source data
                    if !isempty(dst_data) && islast(dst_data, src_data)
                        break
                    end
                    src_tf, src_data = first(Iterators.drop(data, tf_idx))
                    # Can't propagate if the source tf exceedes the target tf
                    if src_tf >= dst_tf
                        dowarn()
                        break
                    end
                    tf_idx += 1
                end
                @deassert contiguous_ts(dst_data.timestamp, string(timeframe!(dst_data)))
            end
        end
    end
end

@doc """Resamples OHLCV data between different time frames.

$(TYPEDSIGNATURES)

This function resamples the OHLCV data from a source DataFrame to a destination DataFrame with different timeframes. If the latest timestamp in the destination DataFrame is earlier than the earliest timestamp in the resampled source DataFrame, the function appends the resampled data to the destination DataFrame. If not, the function returns the destination DataFrame as is.
Both the source and destination DataFrames must have columns named 'timestamp', 'open', 'high', 'low', 'close', and 'volume'.
The source and destination timeframes must be suitable for the resampling operation.
"""
function propagate_ohlcv!(
    src::DataFrame,
    dst::DataFrame;
    src_tf=timeframe!(src),
    dst_tf=timeframe!(dst),
    strict=true,
)
    if isempty(dst)
        new = resample(src, src_tf, dst_tf)
        addcols!(new, dst)
        append!(dst, new)
    else
        date_dst = lastdate(dst)
        min_rows = count(src_tf, dst_tf)
        if strict && nrow(src) < min_rows
            @warn "Source dataframe ($(src_tf)) doesn't have enough rows for resampling $(nrow(src)) < $min_rows"
            return dst
        end
        src_slice = @view src[rangeafter(src.timestamp, date_dst), :]
        # Same check as before but over the slice
        if strict && nrow(src_slice) < min_rows
            return dst
        end
        new = resample(src_slice, src_tf, dst_tf)
        isempty(new) && return dst
        if isleftadj(date_dst, firstdate(new), dst_tf)
            addcols!(new, dst)
            append!(dst, new)
        else
            dst
        end
    end
end

function propagate_ohlcv!(base_tf, base_data, tf, tf_data)
    propagate_ohlcv!(base_data, tf_data; src_tf=base_tf, dst_tf=tf)
end

export propagate_ohlcv!
