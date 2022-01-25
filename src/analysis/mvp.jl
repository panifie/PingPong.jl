@doc "Momentum, volume, price indicator."
module MVP

using Statistics: mean
using DataFrames: AbstractDataFrame
using Backtest.Misc: PairData
using Base: @kwdef

@doc "Ratio is the minimum number of green candles required. Window is how many previous candles to consider."
function momentum(close::AbstractVector; window=15)
    green = 0
    for w in 1:window
        close[end-w] < close[end-w+1] && begin green += 1 end
    end
    @debug "Green candles ratio: $(green / window)"
    green / window
end

@doc "Ratio is the minimum percent increment of volume during the window period."
function volume(vol::AbstractVector; window=15)
    @views rel = sum(vol[end-window:end]) / sum(vol[end-window*2-1:end-window-1])
    @debug "Volume ratio between the last $window candles and the $(window) candles before those: $rel"
    rel
end

function price(close::AbstractVector; window=15)
    @views rel = mean(close[end-window:end]) / mean(close[end-window*2-1:end-window-1])
    @debug "Price ratio between the last $window candles and the $(window) candles before those: $rel"
    rel
end

@kwdef mutable struct MVPRatios
    m::Float64 = 0.8
    v::Float64 = 1.25
    p::Float64 = 1.2
end

@doc "Returns the mvp-ness of a pair as a sum of each condition ratio weighted by `weights`. If `real=false` it will return a `Bool`
indicating if the pair passes the given `ratios`."
function is_mvp(close::AbstractVector, vol::AbstractVector; window=15, ratios=MVPRatios(),
                real=true, weights=(m=0.4, v=0.4, p=0.2))
    length(close) < window * 2 + 2 && return (real ? 0. : (false, (;m=0., v=0., p=0.)))
    m = momentum(close; window)
    v = volume(vol; window)
    p = price(close; window)
    real && return m * weights.m + v * weights.v + p * weights.p
    (m >= ratios.m && v >= ratios.v && p >= ratios.p, (;m, v, p))
end

is_mvp(df::AbstractDataFrame; kwargs...) = is_mvp(df.close, df.volume; kwargs...)
is_mvp(p::Pair{String, PairData}; kwargs...) = is_mvp(p[2].data; kwargs...)
is_mvp(p::PairData; kwargs...) = is_mvp(p.data; kwargs...)

@doc ""
function discrete_mvp(data::AbstractDict{String,PairData}; atleast = 3, window = 15, decrement=0.025)
    pass = []
    ratios = MVPRatios()
    step = 1. - decrement
    while length(pass) < atleast && ratios.m > 0.01
        empty!(pass)
        for p in values(data)
            b, r = is_mvp(p.data; window, real = false, ratios)
            b && push!(pass, (p.name, r))
        end
        ratios.m *= step
        ratios.v *= step
        ratios.p *= step
    end
    pass, ratios
end

export is_mvp, discrete_mvp

end
