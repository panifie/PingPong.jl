@doc """ Calculates the live profit and loss for a given position.

$(TYPEDSIGNATURES)

This function calculates the live profit and loss (PnL) for a given position in a live trading strategy. 
It fetches the current position from the exchange and compares it with the position in the strategy. 
If there is a discrepancy, it synchronizes the position and recalculates the PnL. 
The function returns the calculated PnL.

"""
function live_pnl(
    s::LiveStrategy,
    ai,
    p::ByPos;
    update::Option{PositionTuple}=nothing,
    synced=true,
    verbose=true,
    waitfor=Second(5),
    kwargs...,
)
    pside = posside(p)
    eid = exchangeid(ai)
    update = @something update live_position(s, ai, pside; kwargs...)
    lp = update.resp
    pos = position(ai, p)
    pnl = resp_position_unpnl(lp, eid)
    if iszero(pnl)
        amount = resp_position_contracts(lp, eid)
        function dowarn(a, b)
            @warn "live pnl: position amount not matching exchange" ai = raw(ai) exc = nameof(
                exchange(ai)
            ) a != b
        end
        sync = false
        if amount > zero(DFT)
            if !isapprox(amount, abs(cash(pos)))
                verbose && dowarn(amount, abs(cash(pos).value))
                sync = true
            end
            ep = resp_position_entryprice(lp, eid)
            if !isapprox(ep, entryprice(pos))
                verbose && dowarn(amount, entryprice(pos))
                sync = true
            end
            if synced || sync
                @timeout_start
                waitsync(ai; since=update.date, waitfor)
                live_sync_position!(s, ai, pside, update; commits=false)
            end
            Instances.pnl(pos, _ccxtposprice(ai, lp))
        else
            pnl
        end
    else
        pnl
    end
end
