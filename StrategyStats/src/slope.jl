using Indicators;
const ind = Indicators;
using Data.DataFrames: DataFrame, AbstractDataFrame

@doc """Applies a slope filter to a dataset.

$(TYPEDSIGNATURES)

This function applies a slope filter to a dataset. It checks whether the slope of a linear regression line fit to the data meets certain criteria, and retains only those data points that pass the filter.

"""
function slopefilter(
    timeframe=config.min_timeframe; qc=config.qc, minv=10.0, maxv=90.0, window=20
)
    @assert exc.issset "Global exchange variable is not set."
    pairs = tickers(exc, qc)
    pairs = load_ohlcv(zi, exc, pairs, timeframe)
    pred = x -> slopeangle(x; window)
    filterminmax(pred, pairs, minv, maxv)
end

@doc "[`slopefilter`](@ref) over a dictionary."
function slopefilter(pairs::AbstractDict; minv=10.0, maxv=90.0, window=20)
    pred = x -> slopeangle(x; window)
    filterminmax(pred, pairs, minv, maxv)
end

slopeangle(data::AbstractDataFrame; kwargs...) = slopeangle(data.close; kwargs...)

@doc """Calculates the slope angle for a given array.

$(TYPEDSIGNATURES)

This function takes an array `arr` and optionally an integer `n` (default is 10). It calculates the slope angle of a linear regression line fit to the last `n` data points in `arr`.

"""
function slopeangle(arr; n=10)
    size(arr)[1] >= n || return [missing]
    slopetoangle.(ind.mlr_slope(arr; n))
end

slopetoangle(s) = begin
    atan(s) * (180 / π)
end

@doc """Checks if slope of a DataFrame is within certain bounds.

$(TYPEDSIGNATURES)

This function takes a DataFrame `ohlcv` and optionally three integers `mn` (default is 5), `mx` (default is 90), and `n` (default is 26). It checks if the slope of a linear regression line fit to the last `n` data points in `ohlcv` is between `mn` and `mx`.

"""
function is_slopebetween(ohlcv::DataFrame; mn=5, mx=90, n=26)
    slope = ind.mlr_slope(@view(ohlcv.close[(end - n):end]); n)[end]
    angle = atan(slope) * (180 / π)
    mx > angle > mn
end
