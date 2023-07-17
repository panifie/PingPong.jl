using Data.DataStructures: SortedDict
using Data: contiguous_ts
using .Lang: @deassert

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
