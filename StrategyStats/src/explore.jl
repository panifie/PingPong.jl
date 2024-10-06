using ExchangeTypes: exc
using Data: load, zi, PairData, OHLCV_COLUMNS

include("metrics.jl")

@doc "See [`find_bottomed`](@ref).

$(TYPEDSIGNATURES)"
function find_bottomed(pairs::AbstractDict{String,PairData}; kwargs...)
    find_bottomed(collect(values(pairs)); kwargs...)
end

@doc """Finds pairs that have bottomed out in the given data for long positions.

$(TYPEDSIGNATURES)

The `find_bottomed` function takes the following parameters:

- `pairs`: an AbstractVector of PairData objects that represent pair data.
- `bb_thresh` (optional, default is 0.05): a threshold value which the Bollinger Bands value must exceed to be considered a bottom.
- `up_thresh` (optional, default is 0.05): a threshold value which the price change must exceed to be considered an uptrend.
- `n` (optional, default is 12): an integer that represents the number of periods to consider for the bottom and uptrend detection.
- `mn` (optional, default is 1.0): a minimum value for the price to be considered a bottom.
- `mx` (optional, default is 90.0): a maximum value for the price to be considered a bottom.

The function scans through the pairs in the `pairs` vector and determines which pairs have bottomed out based on the specified criteria.

The function returns a list of pairs that have bottomed out for long positions.
"""
function find_bottomed(
    pairs::AbstractVector{PairData}; bb_thresh=0.05, up_thresh=0.05, n=12, mn=1.0, mx=90.0
)
    bottomed = Dict()
    for p in pairs
        if is_bottomed(p.data; thresh=bb_thresh, n) &&
            is_uptrend(p.data; thresh=up_thresh, n) &&
            is_slopebetween(p.data; n, mn, mx)
            bottomed[p.name] = p
        end
    end
    bottomed
end

@doc "See [`find_peaked`](@ref).

$(TYPEDSIGNATURES)
"
function find_peaked(pairs::AbstractDict{String,PairData}; kwargs...)
    find_peaked(collect(values(pairs)); kwargs...)
end

@doc """Complementary to [`find_bottomed`](@ref).

$(TYPEDSIGNATURES)
"""
function find_peaked(
    pairs::AbstractVector{PairData}; bb_thresh=-0.05, up_thresh=0.05, n=12, mn=-0.90, mx=0
)
    peaked = Dict()
    for p in pairs
        if is_peaked(p.data; thresh=bb_thresh, n) &&
            !is_uptrend(p.data; thresh=up_thresh, n) &&
            is_slopebetween(p.data; n, mn, mx)
            peaked[p.name] = p
        end
    end
    peaked
end

export find_bottomed
