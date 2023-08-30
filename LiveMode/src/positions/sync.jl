function live_sync_position!(
    s::LiveStrategy,
    ai::MarginInstance,
    p::Option{ByPos},
    update::Py;
    amount=resp_position_contracts(update, exchangeid(ai)),
    ep_in=resp_position_entryprice(update, exchangeid(ai)),
    commits=true,
)
    eid = exchangeid(ai)
    pside = posside_fromccxt(update, eid, p)
    pos = position(ai, pside)

    # check hedged mode
    resp_position_hedged(update, eid) == ishedged(pos) ||
        @warn "Position hedged mode mismatch (local: $(pos.hedged))"
    @assert ishedged(pos) || !isopen(opposite(ai, pside)) "Double position open in NON hedged mode."
    this_time = resp_position_timestamp(update, eid)
    pos.timestamp[] == this_time && return pos

    # Margin/hedged mode are immutable so just check for mismatch
    let mm = resp_position_margin_mode(update, eid)
        pyisnone(mm) ||
            pyeq(Bool, mm, _ccxtmarginmode(pos)) ||
            @warn "Position margin mode mismatch local: $(marginmode(pos)), remote: $(mm)"
    end

    # update cash, (always positive for longs, or always negative for shorts)
    cash!(pos, islong(pos) ? positive(amount) : negative(amount))
    # If the updated amount is "dust" the position should be considered closed, and to be reset
    pos_price = _ccxtposprice(ai, update)
    if isdust(ai, pos_price, pside)
        reset!(pos)
        return pos
    end
    pos.status[] = PositionOpen()
    ai.lastpos[] = pos
    dowarn(what, val) = @warn "Unable to sync $what from $(nameof(exchange(ai))), got $val"
    # price is always positive
    ep = ep_in::DFT
    ep = if ep > zero(DFT)
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

    lev = resp_position_leverage(update, eid)
    if lev > zero(DFT)
        leverage!(pos, lev)
    else
        dowarn("leverage", lev)
        lev = one(DFT)
    end
    ntl = let v = resp_position_notional(update, eid)
        if v > zero(DFT)
            notional!(pos, v)
            notional(pos)
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
    lqp = resp_position_liqprice(update, eid)
    liqprice_set = lqp > zero(DFT) && (liqprice!(pos, lqp); true)

    mrg = resp_position_initial_margin(update, eid)
    coll = resp_position_collateral(update, eid)
    adt = max(zero(DFT), coll - mrg)
    mrg_set = mrg > zero(DFT) && begin
        initial!(pos, mrg)
        additional!(pos, adt)
        true
    end
    mm = resp_position_maintenance_margin(update, eid)
    mm_set = mm > zero(DFT) && (maintenance!(pos, mm); true)
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
                pside, ep, lev, _ccxtmmr(update, pos, eid); additional=adt, notional=ntl
            ),
        )
    end
    mrg_set || _margin!()
    mm_set || update_maintenance!(pos; mmr=_ccxtmmr(update, pos, eid))
    function higherwarn(whata, whatb, a, b)
        "($(raw(ai))) $whata ($(a)) can't be higher than $whatb $(b)"
    end
    @assert maintenance(pos) <= collateral(pos) higherwarn(
        "maintenance", "collateral", maintenance(pos), collateral(pos)
    )
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
    timestamp!(pos, resp_position_timestamp(update, eid))
    return pos
end

function live_sync_position!(s::LiveStrategy, ai::MarginInstance; since=nothing, kwargs...)
    @sync for pos in (Long, Short)
        @async let update = live_position(s, ai, pos; since)
            isnothing(update) || live_sync_position!(s, ai, pos, update; kwargs...)
        end
    end
end
