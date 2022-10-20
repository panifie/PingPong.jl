using Backtest.Misc: PairData

find_bottomed(pairs::AbstractDict{String,PairData}; kwargs...) =
    find_bottomed(collect(values(pairs)); kwargs...)

@doc "Find bottomed longs."
function find_bottomed(
    pairs::AbstractVector{PairData};
    bb_thresh = 0.05,
    up_thresh = 0.05,
    n = 12,
    mn = 1.0,
    mx = 90.0,
)
    bottomed = Dict()
    for p in pairs
        if is_bottomed(p.data; thresh = bb_thresh, n) &&
           is_uptrend(p.data; thresh = up_thresh, n) &&
           is_slopebetween(p.data; n, mn, mx)
            bottomed[p.name] = p
        end
    end
    bottomed
end

find_peaked(pairs::AbstractDict{String,PairData}; kwargs...) =
    find_peaked(collect(values(pairs)); kwargs...)

@doc "Find peaked shorts."
function find_peaked(
    pairs::AbstractVector{PairData};
    bb_thresh = -0.05,
    up_thresh = 0.05,
    n = 12,
    mn = -0.90,
    mx = 0,
)
    peaked = Dict()
    for p in pairs
        if is_peaked(p.data; thresh = bb_thresh, n) &&
           !is_uptrend(p.data; thresh = up_thresh, n) &&
           is_slopebetween(p.data; n, mn, mx)
            peaked[p.name] = p
        end
    end
    peaked
end

function plot_trendlines(pair::AbstractString, timeframe = "4h")
    data = load_pair(zi, exc.name, pair, timeframe)
    tsr = TS(convert(Matrix{Float64}, data, data.timestamp, OHLCV_COLUMNS))
    maxi = maxima(tsr)
    mini = minima(tsr)
end

# function plotstuff(d)
#     @df d scatter(
#         :timestamp,
#         :close,
#     )
# end

export find_bottomed

