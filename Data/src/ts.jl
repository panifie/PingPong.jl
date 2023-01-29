using Temporal: TS
using Data: OHLCV_COLUMNS_TS

@doc "Converts ohlcv dataframe to timeseries type."
macro ohlc(df, tp=Float64)
    df = esc(:df)
    quote
        TS(
            @to_mat(@view($df[:, OHLCV_COLUMNS_TS]), $tp),
            $df.timestamp,
            OHLCV_COLUMNS_TS,
        )
    end
end

@doc "Converts a subset of columns to timeseries."
macro as_ts(df, c1, cols...)
    df = esc(df)
    local columns
    if cols[1] isa QuoteNode
        columns = [c.value for c in cols]::Vector{Symbol}
        return nothing
    else
        @assert size(cols, 1) === 1
        columns = esc(cols[1])
    end
    if length(cols) === 0
        quote
            TS(getproperty($df, $c1), $df.timestamp, $c1)
        end
    else
        quote
            if !isdefined(Main, :type)
                type = Float64
            end
            idx = hasproperty($df, :timestamp) ? $(df).timestamp : $(esc(:dates))
            ns = vcat([$c1]::Vector{Symbol}, $columns::Vector{Symbol})
            TS(@to_mat(@view($df[:, ns])), idx, ns)
        end
    end
end

@doc "Get the last date of loaded data (in `mrkts` variable)."
macro otime()
    m = esc(:mrkts)
    quote
        first($m).second.data[end, :timestamp]
    end
end
