function slippage_rate(::Val{:below}, target, total; n=2.828145, fn=x -> x^2)
    @deassert target < total
    fn(target / (n * total))
end

function slippage_rate(::Val{:above}, target, total; n=0.5, fn=x -> x^3)
    @deassert target >= total
    fn(n * (target / total))
end

@doc "Given two numbers (trade amount, candle volume) or (limit price, candle price) get a rate
that signifies slippage magnitude."
function slippage_rate(target, total)
    if target < total
        slippage_rate(Val(:below), target, total)
    else
        slippage_rate(Val(:above), target, total)
    end
end

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

export slippage, slippageat
