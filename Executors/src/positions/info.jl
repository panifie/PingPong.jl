using OrderTypes: LiquidationTrade

@doc "The number of liquidations that have happened for an asset instance."
function liquidations(ai::MarginInstance)
    short_liq = Trade[]
    long_liq = Trade[]
    for t in ai.history
        if t isa LiquidationTrade
            if orderpos(t) == Long
                push!(long_liq, t)
            else
                push!(short_liq, t)
            end
        end
    end
    (long=long_liq, short=short_liq)
end
