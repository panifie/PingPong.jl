using Data.DataStructures: SortedDict
using Data: contiguous_ts
using Data.DFUtils: addcols!
using .Lang: @deassert
using Misc.DocStringExtensions
using Misc: rangeafter
import Data: propagate_ohlcv!

@doc """
    propagate_ohlcv!(data, update_func)

Update the OHLCV data from the base to the higher time frames in =data=.

=update_func= is a function that aggregates the OHLCV values from the base to the target time frame.
The function modifies =data= in place and returns it.
If the base data frame is empty, the function empties all the higher time frames data frames.
Otherwise, the function updates each higher time frame data frame asynchronously and checks the timestamps.
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
        for (tf, tf_data) in props_itr
            let src_data = base_data, src_tf = base_tf, tf_idx = 1, hasrows = !isempty(tf_data)
                dowarn() = @debug "Failed to propagate ohlcv from $base_tf..$src_tf to $tf"
                while true
                    tf_idx >= props_n && (dowarn(); break)
                    if nrow(src_data) < count(src_tf, tf)
                        src_tf, src_data = first(Iterators.drop(data, tf_idx))
                        hasrows && islast(tf_data, src_data) && break
                        # Can't propagate if the source tf exceedes the target tf
                        src_tf >= tf && (dowarn(); break)
                        tf_idx += 1
                        continue
                    end
                    tf_idx += 1
                    update_func(src_tf, src_data, tf, tf_data)
                    hasrows && islast(tf_data, src_data) && break
                    src_tf, src_data = first(Iterators.drop(data, tf_idx))
                    src_tf >= tf && (dowarn(); break)
                end
                @deassert contiguous_ts(tf_data.timestamp, string(timeframe!(tf_data)))
            end
        end
    end
end

@doc """
    $(TYPEDSIGNATURES)

Resample the OHLCV data from a source DataFrame to a destination DataFrame with different timeframes.
If the last date of the destination DataFrame is before the first date of the resampled source DataFrame,
append the resampled data to the destination DataFrame. Otherwise, return the destination DataFrame as is.
The source and destination DataFrames must have columns named timestamp, open, high, low, close, and volume.
The source and destination timeframes must be compatible with the resample function.
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
        strict && nrow(src_slice) < min_rows && return dst
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
