@doc """ Compute the slippage at a specific date for an asset instance

$(TYPEDSIGNATURES)

This function calculates the slippage for a specific asset instance at a given date.
Slippage refers to the difference between the expected price of a trade and the price at which the trade is actually executed.
It uses the open-close spread and the high-low spread to compute the slippage.

"""
function slippageat(inst::AssetInstance, date::DateTime; kwargs...)
    idx = dateindex(df, date)
    slippageat(ohlcv(inst), idx; kwargs...)
end

@doc """ Compute the slippage for an asset instance

$(TYPEDSIGNATURES)

This function calculates the slippage for a specific asset instance. 
Slippage refers to the difference between the expected price of a trade and the price at which the trade is actually executed. 
It uses the current date's open-close spread and the high-low spread to compute the slippage.

"""
function slippageat(inst::AssetInstance; kwargs...)
    data = ohlcv(inst)

    date = data.timestamp[end]
    idx = dateindex(df, date)
    slippageat(data, idx; kwargs...)
end


export slippageat
