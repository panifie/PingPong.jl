macro warn_unsynced(what, loc, rem, msg="unsynced")
    ex = quote
        (
            wasopen &&
            @warn "Position $($msg) ($($what)) local: $($loc), remote: $($rem) ($(raw(ai))@$(nameof(s)))"
        )
    end
    esc(ex)
end

function live_sync_position!(
    s::LiveStrategy,
    ai::MarginInstance,
    p::Option{ByPos},
    update::PositionUpdate7;
    amount=resp_position_contracts(update.resp, exchangeid(ai)),
    ep_in=resp_position_entryprice(update.resp, exchangeid(ai)),
    commits=true,
    skipchecks=false,
)
    eid = exchangeid(ai)
    resp = update.resp
    pside = posside_fromccxt(resp, eid, p)
    pos = position(ai, pside)
    wasopen = isopen(pos) # by macro warn_unsynced

    # check hedged mode
    resp_position_hedged(resp, eid) == ishedged(pos) ||
        @warn "Position hedged mode mismatch (local: $(pos.hedged))"
    skipchecks || begin
        if !ishedged(pos) && isopen(opposite(ai, pside))
            @warn "Double position open in NON hedged mode. Resetting opposite side." opposite_side = opposite(
                pside
            ) raw(ai) nameof(s)
            pong!(s, ai, opposite(pside), now(), PositionClose())
            if isopen(opposite(ai, pside))
                @error "Failed to close opposite position" opposite_position = opposite(
                    ai, pside
                ) raw(ai) nameof(s)
            end
        end
        update.read[] && return pos
    end

    if update.closed[]
        isdust(ai, _ccxtposprice(ai, resp), pside) ||
            @warn "Position cash expected to be (close to) zero, found $(cash(ai, pside))"
        update.read[] = true
        reset!(pos)
        return pos
    end

    # Margin/hedged mode are immutable so just check for mismatch
    let mm = resp_position_margin_mode(resp, eid)
        pyisnone(mm) ||
            pyeq(Bool, mm, _ccxtmarginmode(pos)) ||
            @warn "Position margin mode mismatch local: $(marginmode(pos)), remote: $(mm)"
    end

    # resp cash, (always positive for longs, or always negative for shorts)
    let rv = islong(pos) ? positive(amount) : negative(amount)
        isapprox(ai, cash(pos), rv, Val(:amount)) ||
            @warn_unsynced "amount" cash(pos) amount
        cash!(pos, rv)
    end
    # If the respd amount is "dust" the position should be considered closed, and to be reset
    pos_price = _ccxtposprice(ai, resp)
    if isdust(ai, pos_price, pside)
        update.read[] = true
        reset!(pos)
        return pos
    end
    pos.status[] = PositionOpen()
    ai.lastpos[] = pos
    dowarn(what, val) = @warn "Unable to sync $what from $(nameof(exchange(ai))), got $val"
    # price is always positive
    ep = pytofloat(ep_in)
    ep = if ep > zero(DFT)
        isapprox(entryprice(pos), ep; rtol=1e-3) ||
            @warn_unsynced "entryprice" entryprice(pos) ep
        entryprice!(pos, ep)
        ep
    else
        entryprice!(pos, pos_price)
        dowarn("entry price", ep)
        pos_price
    end
    commits && let comm = committed(s, ai, pside)
        isapprox(committed(pos).value, comm) || commit!(pos, comm)
    end

    lev = resp_position_leverage(resp, eid)
    if lev > zero(DFT)
        isapprox(leverage(pos), lev; atol=1e-2) ||
            @warn_unsynced "leverage" leverage(pos) lev
        leverage!(pos, lev)
    else
        dowarn("leverage", lev)
        lev = one(DFT)
    end
    ntl = let v = resp_position_notional(resp, eid)
        if v > zero(DFT)
            ntl = notional(pos)
            isapprox(ntl, v; rtol=0.05) ||
                @warn_unsynced "notional" ntl v "error too high"
            notional!(pos, v)
            v
        else
            let a = ai.asset
                spot_sym = "$(bc(a))/$(sc(a))"
                price = try
                    # try to use the price of the settlement cur
                    lastprice(spot_sym, exchange(ai))
                catch
                    # or fallback to price of quote cur
                    pos_price
                end
                v = price * cash(pos)
                notional!(pos, v)
                notional(pos)
            end
        end
    end
    @assert ntl > ZERO "Notional can't be zero"

    tier!(pos, ntl)
    lqp = resp_position_liqprice(resp, eid)
    # NOTE: Also don't warn about liquidation price because same as notional
    liqprice_set =
        lqp > zero(DFT) && begin
            isapprox(liqprice(pos), lqp; rtol=0.05) ||
                @warn_unsynced "liqprice" liqprice(pos) lqp "error too high"
            liqprice!(pos, lqp)
            true
        end

    mrg = resp_position_initial_margin(resp, eid)
    coll = resp_position_collateral(resp, eid)
    adt = max(zero(DFT), coll - mrg)
    mrg_set =
        mrg > zero(DFT) && begin
            isapprox(mrg, margin(pos); rtol=1e-2) ||
                @warn_unsynced "initial margin" margin(pos) mrg
            initial!(pos, mrg)
            isapprox(adt, additional(pos); rtol=1e-2) ||
                @warn_unsynced "additional margin" additional(pos) adt
            additional!(pos, adt)
            true
        end
    mm = resp_position_maintenance_margin(resp, eid)
    mm_set =
        mm > zero(DFT) && begin
            isapprox(mm, maintenance(pos); rtol=0.05) ||
                @warn_unsynced "maintenance margin" maintenance(pos) mm
            maintenance!(pos, mm)
            true
        end
    # Since we don't know if the exchange supports all position fields
    # try to emulate the ones not supported based on what is available
    _margin!() = begin
        margin!(pos; ntl, lev)
        additional!(pos, max(zero(DFT), coll - margin(pos)))
    end

    liqprice_set || begin
        liqprice!(
            pos,
            liqprice(
                pside, ep, lev, _ccxtmmr(resp, pos, eid); additional=adt, notional=ntl
            ),
        )
    end
    mrg_set || _margin!()
    mm_set || resp_maintenance!(pos; mmr=_ccxtmmr(resp, pos, eid))
    function higherwarn(whata, whatb, a, b)
        "($(raw(ai))) $whata ($(a)) can't be higher than $whatb $(b)"
    end
    @assert maintenance(pos) <= collateral(pos) higherwarn(
        "maintenance", "collateral", maintenance(pos), collateral(pos)
    )

    @assert liqprice(pos) > ZERO "liqprice can't be negative ($(liqprice(pos)))"
    @assert entryprice(pos) > ZERO "entryprice can't be negative ($(entryprice(pos)))"
    @assert notional(pos) > ZERO "notional can't be negative ($(notional(pos)))"

    @assert liqprice(pos) <= entryprice(pos) || isshort(pside) higherwarn(
        "liquidation price", "entry price", liqprice(pos), entryprice(pos)
    )
    @assert committed(pos) <= abs(cash(pos)) higherwarn(
        "committment", "cash", committed(pos), cash(pos).value
    )
    @assert leverage(pos) <= maxleverage(pos) higherwarn(
        "leverage", "max leverage", leverage(pos), maxleverage(pos)
    )
    @assert pos.min_size <= notional(pos) higherwarn(
        "min size", "notional", pos.min_size, notional(pos)
    )
    timestamp!(pos, resp_position_timestamp(resp, eid))
    update.read[] = true
    return pos
end

function live_sync_position!(
    s::LiveStrategy, ai::MarginInstance, pos::ByPos; since=nothing, kwargs...
)
    update = live_position(s, ai, pos; since)
    isnothing(update) || live_sync_position!(s, ai, pos, update; kwargs...)
end

function live_sync_position!(s::LiveStrategy, ai::MarginInstance; kwargs...)
    @sync for pos in (Long, Short)
        @async live_sync_position!(s, ai, pos; kwargs...)
    end
end

@doc """ Asset balance is the position of the asset when margin is involved.

"""
function live_sync_universe_cash!(s::MarginStrategy{Live}; kwargs...)
    long, short = get_positions(s)
    default_date = now()
    function dosync(ai, side, dict)
        update = get(dict, raw(ai), nothing)
        if isnothing(update)
            update = live_position(s, ai, side; force=true)
        end
        if isnothing(update)
            reset!(ai, Long())
            reset!(ai, Short())
        else
            live_sync_position!(s, ai, side, update; kwargs...)
        end
    end
    @sync for ai in s.universe
        @async begin
            @sync begin
                @async @lock ai dosync(ai, Long(), long)
                @async @lock ai dosync(ai, Short(), short)
            end
            set_active_position!(ai; default_date)
        end
    end
end
