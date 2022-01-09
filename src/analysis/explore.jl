
find_bottomed(pairs::AbstractDict{String, PairData}) = find_bottomed(collect(values(pairs)))

function find_bottomed(pairs::AbstractVector{PairData})
    bottomed = []
    for p in pairs
        is_bottomed(p.data) && push!(bottomed, p)
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
