function live_pnl(s::LiveStrategy, ai, p::ByPos; force_resync=:auto, verbose=true)
    pside = posside(p)
    lp = live_position(s, ai::MarginInstance, pside)
    pos = position(ai, p)
    pnl = get_float(lp, Pos.unrealizedPnl)
    if iszero(pnl)
        amount = get_float(lp, "contracts")
        function dowarn(a, b)
            @warn "Position amount for $(raw(ai)) unsynced from exchange $(nameof(exchange(ai))) ($a != $b), resyncing..."
        end
        resync = false
        if amount > zero(DFT)
            if !isapprox(amount, abs(cash(pos)))
                verbose && dowarn(amount, abs(cash(pos).value))
                resync = true
            end
            ep = live_entryprice(lp)
            if !isapprox(ep, entryprice(pos))
                verbose && dowarn(amount, entryprice(pos))
                resync = true
            end
            if force_resync == :yes || (force_resync == :auto && resync)
                live_sync_position!(s, ai, pside, lp; commits=false)
            end
            Instances.pnl(pos, _ccxtposprice(ai, lp))
        else
            pnl
        end
    else
        pnl
    end
end
