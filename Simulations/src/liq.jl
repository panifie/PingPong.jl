
@doc """ Compute the liquidity 

$(TYPEDSIGNATURES)

This function calculates the liquidity by dividing the volume by the difference between the high and low prices and then multiplying by the close price.
Liquidity is a measure of the ability to buy or sell an asset without causing a significant change in its price.

"""
function liquidity(volume, close, high, low)
    return log10((volume * close) / (high - low))
end

@doc """ Compute the liquidity at a specific index 

$(TYPEDSIGNATURES)

This function calculates the liquidity at a specific index by dividing the volume at that index by the difference between the high and low prices at that index, and then multiplying by the close price at that index.
Liquidity is a measure of the ability to buy or sell an asset without causing a significant change in its price.

"""
function liqat(idx::Integer, volume::V, close::V, high::V, low::V) where {V<:AbstractVector}
    liquidity(volume[idx], close[idx], high[idx], low[idx])
end

@doc """ Compute the illiquidity at a specific index 

$(TYPEDSIGNATURES)

This function calculates the illiquidity at a specific index over a specified window by dividing the absolute return by the volume.
The absolute return is calculated by taking the difference between the close prices at the current and previous indices.
Illiquidity is a measure of the difficulty faced in buying or selling an asset without affecting its price.

"""
function illiqat(idx::Integer, close::T, volume::T; window=120) where {T<:AbstractVector}
    start = idx - window + 1
    start > 0 || return missing
    close_win = view(close, start:idx)
    # volume in quote currency
    volume_at = volume[idx] * close[idx]
    prev_close = mt.lagged(close, window; idx)
    returns_volume_ratio = abs.(((close_win .- prev_close)) ./ volume_at)
    return sum(returns_volume_ratio) / window * 1e6
end


# liquidation price = entry price - (1/leverage ratio) * entry price
