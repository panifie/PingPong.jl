using Temporal: TS
using Indicators
using DataFramesMeta

macro as_ts(df, c1, cols...)
    df = esc(df)
    if length(cols) === 0
        quote
            TS(getproperty($df, $c1), $df.timestamp, $c1)
        end
    else
        quote
            if !isdefined(Main, :type)
                type = Float64
            end
            idx = hasproperty($df, :timestamp) ? $df.timestamp : $(esc(:dates))
            ns = vcat([$c1]::Vector{Symbol}, collect(c.value for c in $cols)::Vector{Symbol})
	        TS(@to_mat(@view($df[:, ns])), idx, ns)
        end
    end
end

function maxmin(df; order=1, threshold=0.0, window=100)
    tsr = @as_ts df :close
    df[:, :maxima] .= NaN
    df[:, :minima] .= NaN
    dfv = @view df[window+2:end, :]
    mat = @to_mat df eltype(df.close)
    # prev_window = window - 2
    @eachrow! dfv begin
        stop = row+window
        # ensure no lookahead bias
        # @assert tsr.index[stop] < :timestamp
        @assert df.timestamp[stop] < :timestamp
        # subts = @view(tsr.values[row:stop])
        subts = @view(mat[row:stop, 2:end-1])
        mx = maxima(subts; order, threshold)
        local ma = mi = NaN
        for (n, x) in enumerate(mx)
            if x
                ma = n
                break
            end
        end
        mn = minima(subts; order, threshold)
        for (n, x) in enumerate(mn)
            if x
                mi = n
                break
            end
        end
        :maxima = ma > mi
        :minima = mi > ma
    end
    df
end

function supres(df, window=30)
    tsr = @ohlc(df)
    df[!, :support] .= NaN
    df[!, :resistance] .= NaN
    start = window
    w = window - 1
    subdf = @view df[window:end, :]
    @eachrow! subdf begin
        # row > start && begin
            # w_tsr = TS(@view(tsr.values[row-window:row, :]), @view(tsr.index[row-window:row]), OHLCV_COLUMNS_TS)
        # w_tsr = TS(@view(tsr.values[row:row+w, 4]), @view(tsr.index[row:row+w]))
        vr = df.close[row:row+w]
        for v in Iterators.reverse(resistance(vr))
            @show v
            if !isnan(v)
                :resistance = v
                break
            end
        end
        for s in Iterators.reverse(support(vr))
            @show s
            if !isnan(s)
                :support = s
                break
            end
        end
        # :resistance = resistance(w_tsr).values[end-3, 1]
        # :support = support(w_tsr).values[end-3, 1]
    end
end
