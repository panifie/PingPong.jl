using Indicators;
const ind = Indicators;
using DataFrames: DataFrame, AbstractDataFrame

function slopefilter(
    timeframe=config.timeframe; qc=config.qc, minv=10.0, maxv=90.0, window=20
)
    @assert exc.issset "Global exchange variable is not set."
    pairs = tickers(exc, qc)
    pairs = load_ohlcv(zi, exc, pairs, timeframe)
    pred = x -> slopeangle(x; window)
    filter(pred, pairs, minv, maxv)
end

function slopefilter(pairs::AbstractDict; minv=10.0, maxv=90.0, window=20)
    pred = x -> slopeangle(x; window)
    filter(pred, pairs, minv, maxv)
end

slopeangle(data::AbstractDataFrame; kwargs...) = slopeangle(data.close; kwargs...)

function slopeangle(arr; n=10)
    size(arr)[1] >= n || return [missing]
    slopetoangle.(ind.mlr_slope(arr; n))
end

slopetoangle(s) = begin
    atan(s) * (180 / π)
end

function is_slopebetween(ohlcv::DataFrame; mn=5, mx=90, n=26)
    slope = ind.mlr_slope(@view(ohlcv.close[(end - n):end]); n)[end]
    angle = atan(slope) * (180 / π)
    mx > angle > mn
end
