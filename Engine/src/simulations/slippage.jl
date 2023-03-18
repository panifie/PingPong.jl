relslippage(trade_vol, candle_vol) = trade_vol / candle_vol
tradeslippage(trade_vol; fn=sqrt) = fn(trade_vol)

function slippage(trade_vol, candle_vol, args...; kwargs...)
    slippage(Val(:rel), trade_vol, candle_vol)
end

function slippageat(::Val{:rel}, df, idx, trade_vol; kwargs...)
    relslippage(trade_vol, df.volume[idx])
end
function slippageat(::Val{:trade}, df, idx, trade_vol; kwargs...)
    tradeslippage(trade_vol; kwargs...)
end

function slippageat(inst::AssetInstance, date::DateTime, v::Val=Val(:rel); kwargs...)
    idx = dateindex(df, date)
    slippageat(v, inst.ohlcv, idx; kwargs...)
end

function slippageat(inst::AssetInstance, v::Val=Val(:trade); kwargs...)
    data = inst.ohlcv
    date = data.timestamp[end]
    idx = dateindex(df, date)
    slippageat(v, data, idx; kwargs...)
end

export slippage, slippageat
