
find_bottomed(pairs::AbstractDict{String, PairData}; kwargs...) = find_bottomed(collect(values(pairs)); kwargs...)

function find_bottomed(pairs::AbstractVector{PairData}; bb_thresh=0.05, up_thresh=0.05, n=12)
    bottomed = Dict()
    for p in pairs
        if is_bottomed(p.data; thresh=bb_thresh, n) &&
            is_uptrend(p.data; thresh=up_thresh, n) &&
            is_slopebetween(p.data; n)
            bottomed[p.name] = p
        end
    end
    bottomed
end

using Plots: plot
using StatsPlots

function plot_trendlines(pair::AbstractString, timeframe="4h")
    data = load_pair(zi, exc[].name, pair, timeframe)
    tsr = TS(convert(Matrix{Float64}, data, data.timestamp, OHLCV_COLUMNS))
    maxi = maxima(tsr)
    mini = minima(tsr)
    plot(data)
end

# function plotstuff(d)
#     @df d scatter(
#         :timestamp,
#         :close,
#     )
# end

export find_bottomed
