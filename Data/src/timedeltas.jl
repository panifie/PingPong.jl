
@doc """Check the time delta between two rows in a DataFrame.

$(TYPEDSIGNATURES)

This macro is used to check the time delta between two DataFrame to ensure they are of the same time delta.
It throws a `TimeFrameError` if the time delta does not match the specified time delta value.
If no `args` are provided, the macro uses the `za` value as the default data to check.
"""
macro check_td(args...)
    local check_data
    if !isempty(args)
        check_data = esc(args[1])
    else
        check_data = esc(:za)
    end
    col = esc(:saved_col)
    td = esc(:td)
    quote
        if size($check_data, 1) > 1
            timeframe_match = timefloat($check_data[2, $col] - $check_data[1, $col]) == $td
            if !timeframe_match
                @warn "Saved date not matching timeframe, resetting."
                throw(
                    TimeFrameError(
                        string($check_data[1, $col]),
                        string($check_data[2, $col]),
                        convert(Second, Millisecond($td)),
                    ),
                )
            end
        end
    end
end

# @doc "The time interval of the dataframe, guesses from the difference between the first two rows."
# function data_td(data)
#     @ifdebug @assert size(data, 1) > 1 "Need a timeseries of at least 2 points to find a time delta."
#     data.timestamp[2] - data.timestamp[1]
# end
