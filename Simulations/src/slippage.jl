function slippageat(inst::AssetInstance, date::DateTime; kwargs...)
    idx = dateindex(df, date)
    slippageat(ohlcv(inst), idx; kwargs...)
end

function slippageat(inst::AssetInstance; kwargs...)
    data = ohlcv(inst)

    date = data.timestamp[end]
    idx = dateindex(df, date)
    slippageat(data, idx; kwargs...)
end


export slippageat
