function slippageat(inst::AssetInstance, date::DateTime; kwargs...)
    idx = dateindex(df, date)
    slippageat(inst.ohlcv, idx; kwargs...)
end

function slippageat(inst::AssetInstance; kwargs...)
    data = inst.ohlcv
    date = data.timestamp[end]
    idx = dateindex(df, date)
    slippageat(data, idx; kwargs...)
end


export slippageat
