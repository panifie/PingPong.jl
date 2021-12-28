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

isdown(threshold) = !isup(threshold)

@doc "Calculate successrate of given column against next candle.
`direction`: `true` is buy, `false` is sell."
function up_successrate(df, bcol::Union{Symbol, String}; threshold=0.05)
    bcol_v = getproperty(df, bcol) |> x -> circshift(x, 1)
    bcol_v[1] = NaN
    rate = 0
    tv = 1 + threshold
    @eachrow df begin
        br = bcol_v[row]
        rate += convert(Int, Bool(isnan(br) ? false : br) && :high / :open > tv)
    end
    rate
end

function down_successrate(df, bcol::Union{Symbol, String}; threshold=0.05)
    bcol_v = getproperty(df, bcol) |> x -> circshift(x, 1)
    bcol_v[1] = NaN
    rate = 0
    tv = 1 + threshold
    @eachrow df begin
        br = bcol_v[row]
        rate += convert(Int, Bool(isnan(br) ? false : br) && :open / :low > tv)
    end
    rate
end

@doc "This support and resistance functions from Indicators appear to be too inaccurate despite parametrization."
function supres(df; order=1, threshold=0., window=16)
    df[!, :sup] .= NaN
    df[!, :res] .= NaN
    dfv = @view df[window+2:end, :]
    price = df.close
    local prev_r, prev_s
    @assert window > 15 # use a large enough window size to prevent zero values
    @eachrow! dfv begin
        stop = row+window
        # ensure no lookahead bias
        @debug @assert df.timestamp[stop] < :timestamp
        subts = @view price[row:stop]
        res = resistance(subts; order, threshold)
        sup = support(subts; order, threshold=-threshold)
        r = findfirst(isfinite, res)
        s = findfirst(isfinite, sup)
        :res = isnothing(r) ? prev_r : prev_r = res[r]
        :sup = isnothing(s) ? prev_s : prev_s = sup[s]
        @debug @assert !iszero(prev_r)
    end
    df
end

function renkodf(df; box_size=10., use_atr=false, n=14)
    local rnk_idx
    if use_atr
        type = Float64
        rnk_idx = renko(@to_mat(@view(df[:, [:high, :low, :close]])); box_size, use_atr, n)
    else
        rnk_idx = renko(df.close; box_size)
    end
    # can't use view on sub dataframes
    rnk_df = df[rnk_idx, [:open, :high, :low, :close, :volume]]
    rnk_df[!, :timestamp] = df.timestamp
    rnk_df
end

function slopeangle(df; window=10)
    size(df, 1) > window || return false
    slope = mlr_slope(@view(df.close[end-window:end]); n=window)[end]
    atan(slope) * (180 / π)
end
