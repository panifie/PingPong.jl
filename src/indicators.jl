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
    df[!, :maxima] .= NaN
    df[!, :minima] .= NaN
    dfv = @view df[window+2:end, :]
    price = df.close
    # prev_window = window - 2
    @eachrow! dfv begin
        stop = row+window
        # ensure no lookahead bias
        @assert df.timestamp[stop] < :timestamp
        subts = @view(price[row:stop])
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

function supres(df; order=1, threshold=0., window=30)
    df[!, :sup] .= NaN
    df[!, :res] .= NaN
    dfv = @view df[window+2:end, :]
    price = df.close
    @eachrow! dfv begin
        stop = row+window
        # ensure no lookahead bias
        @assert df.timestamp[stop] < :timestamp
        subts = @view price[row:stop]
        res = resistance(subts; order, threshold)
        sup = support(subts; order, threshold)
        r = findfirst(isfinite, res)
        s = findfirst(isfinite, sup)
        :res = isnothing(r) ? NaN : res[r]
        :sup = isnothing(s) ? NaN : sup[s]
    end
    df
end
