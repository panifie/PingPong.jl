@doc "Momentum, volume, price indicator."
module MVP

using Statistics: mean
using DataFrames: AbstractDataFrame, DataFrame
using Data: PairData
using Base: @kwdef

@doc "Ratio is the minimum number of green candles required."
function momentum(close::AbstractVector)
    green = 0
    len = length(close)
    for c in 1:(len - 1)
        close[c] < close[c + 1] && begin
            green += 1
        end
    end
    @debug "Green candles ratio: $(green / len)"
    green / len
end

@doc "Ratio is the minimum percent increment of volume from the first half of the series."
function volume(vol::AbstractVector; split=2)
    window = length(vol) ÷ split
    @views rel =
        sum(vol[(end - window):end]) / sum(vol[(end - window * 2):(end - window - 1)])
    @debug "Volume ratio between the last $window candles and the $(window) candles before those: $rel"
    rel
end

function price(close::AbstractVector; split=2)
    window = length(close) ÷ split
    @views rel =
        mean(close[(end - window):end]) / mean(close[(end - window * 2):(end - window - 1)])
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
function is_mvp(
    cl::AbstractVector,
    vol::AbstractVector;
    split=2,
    ratios=MVPRatios(),
    real=true,
    weights=(m=0.4, v=0.4, p=0.2),
)
    m = momentum(cl)
    v = volume(vol; split)
    p = price(cl; split)
    real && return m * weights.m + v * weights.v + p * weights.p
    (m >= ratios.m && v >= ratios.v && p >= ratios.p, (; m, v, p))
end

function is_mvp(close, vol, window; real=false, kwargs...)
    length(close) < window * 2 + 2 && return (real ? 0.0 : (false, (; m=0.0, v=0.0, p=0.0)))
    cl, vol = @views close[(end - window + 1):end], vol[(end - window + 1):end]
    is_mvp(cl, vol; real, kwargs...)
end

is_mvp(df::AbstractDataFrame; kwargs...) = is_mvp(df.close, df.volume; kwargs...)
is_mvp(p::Pair{String,PairData}; kwargs...) = is_mvp(p[2].data; kwargs...)
is_mvp(p::PairData; kwargs...) = is_mvp(p.data; kwargs...)

@doc ""
function discrete_mvp(
    data::AbstractDict{String,PairData}; atleast=3, window=15, decrement=0.025
)
    pass = []
    ratios = MVPRatios()
    step = 1.0 - decrement
    while length(pass) < atleast && ratios.m > 0.01
        empty!(pass)
        for p in values(data)
            b, r = is_mvp(p.data.close, p.data.volume, window; real=false, ratios)
            b && push!(pass, (pair=p.name, r...))
        end
        ratios.m *= step
        ratios.v *= step
        ratios.p *= step
    end
    pass, ratios
end

export is_mvp, discrete_mvp

end
