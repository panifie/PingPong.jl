
function find_bottomed(pairs::AbstractVector{PairData})
    for p in pairs
    end
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
