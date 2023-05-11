using OrderTypes: LiquidationTrade

@doc "The number of liquidations that have happened for an asset instance."
function liquidations(ai::MarginInstance)
    short_liq = 0
    long_liq = 0
    for t in ai.history
        if t isa LiquidationTrade
            if tradepos(t) == Long
                long_liq += 1
            else
                short_liq += 1
            end
        end
    end
    (long=long_liq, short=short_liq)
end
