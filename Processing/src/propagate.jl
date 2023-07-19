using Data.DataStructures: SortedDict
using Data: contiguous_ts
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
function propagate_ohlcv!(data::SortedDict{TimeFrame,DataFrame}, update_func::Function)
    base_tf, base_data = first(data)
    if isempty(base_data)
        foreach(empty!, Iterators.drop(values(data), 1))
        return data
    else
        @sync for (tf, tf_data) in Iterators.drop(data, 1)
            @async begin
                update_func(base_tf, base_data, tf, tf_data)
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
    src::DataFrame, dst::DataFrame; src_tf=timeframe!(src), dst_tf=timeframe!(dst)
)
    date_dst = lastdate(dst)
    src_slice = @view src[rangeafter(src.timestamp, date_dst), :]
    new = resample(src_slice, src_tf, dst_tf)
    isempty(new) && return dst
    if isleftadj(date_dst, firstdate(new), dst_tf)
        append!(dst, new)
    else
        dst
    end
end

function propagate_ohlcv!(base_tf, base_data, tf, tf_data)
    propagate_ohlcv!(base_data, tf_data; src_tf=base_tf, dst_tf=tf)
end
