function live_pnl(
    s::LiveStrategy,
    ai,
    p::ByPos;
    update::Option{PositionUpdate7}=nothing,
    force_resync=:auto,
    verbose=true,
    kwargs...
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
            @warn "Position amount for $(raw(ai)) unsynced from exchange $(nameof(exchange(ai))) ($a != $b), resyncing..."
        end
        resync = false
        if amount > zero(DFT)
            if !isapprox(amount, abs(cash(pos)))
                verbose && dowarn(amount, abs(cash(pos).value))
                resync = true
            end
            ep = resp_position_entryprice(lp, eid)
            if !isapprox(ep, entryprice(pos))
                verbose && dowarn(amount, entryprice(pos))
                resync = true
            end
            if force_resync == :yes || (force_resync == :auto && resync)
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
