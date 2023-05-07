using Executors.Instances: MarginInstance

using Base: negate
const LIQUIDATION_BUFFER = negate(0.05)

function isliquidated(ai::MarginInstance, o::Order)
    let low = lowat(ai, o.date)
        buffered = muladd(low, LIQUIDATION_BUFFER, low)
        @deassert buffered <= low
        return liquidation(ai, o) <= buffered
    end
end

function liquidate!(ai::MarginInstance)
end
