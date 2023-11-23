using .OrderTypes: LiquidationTrade

@doc """ The number of liquidations that have happened for an asset instance.

$(TYPEDSIGNATURES)

This function counts the number of liquidations that have occurred in the history of a margin asset instance.

"""
function liquidations(ai::MarginInstance)
    short_liq = Trade[]
    short_loss = 0.0
    long_liq = Trade[]
    long_loss = 0.0
    for t in ai.history
        if t isa LiquidationTrade
            if positionside(t) == Long
                @deassert t.value - t.fees == t.size
                long_loss += abs(t.value / t.leverage)
                push!(long_liq, t)
            else
                @deassert t.value - t.fees == t.size
                short_loss += abs(t.value / t.leverage)
                push!(short_liq, t)
            end
        end
    end
    (;long=long_liq, long_loss, short=short_liq, short_loss)
end
