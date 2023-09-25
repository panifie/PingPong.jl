macro warn_unsynced(what, loc, rem, msg="unsynced")
    ex = quote
        (
            wasopen &&
            @warn "Position $($msg) ($($what)) local: $($loc), remote: $($rem) $this_timestamp ($(raw(ai))@$(nameof(s)))"
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
    overwrite=true,
)
    let queue = asset_queue(s, ai)
        if queue[] > 1
            @debug "sync pos: skipping position sync since events queue is congested ($(queue[]))"
            return nothing
        end
    end
    eid = exchangeid(ai)
    resp = update.resp
    pside = posside_fromccxt(resp, eid, p)
    pos = position(ai, pside)
    wasopen = isopen(pos) # by macro warn_unsynced

    # check hedged mode
    resp_position_hedged(resp, eid) == ishedged(pos) || begin
        @warn "sync pos: hedged mode mismatch (local: $(pos.hedged))"
        marginmode!(exchange(ai), _ccxtmarginmode(ai), raw(ai))
    end
    skipchecks || begin
        if !ishedged(pos) && isopen(opposite(ai, pside))
            let amount = resp_position_contracts(
                    get_positions(s, ai, opposite(pside)).resp, eid
                ),
                oppos = opposite(pside)

                if amount > ZERO
                    @warn "sync pos: double position open in NON hedged mode. Resetting opposite side." oppos raw(
                        ai
                    ) nameof(s)
                    pong!(s, ai, oppos, now(), PositionClose(); amount)
                    if isopen(opposite(ai, pside))
                        @error "sync pos: failed to close opposite position" opposite_position = position(
                            ai, oppos
                        ) raw(ai) nameof(s)
                        return pos
                    end
                else
                    @debug "sync pos: resetting opposite position" ai = raw(ai) oppos
                    reset!(ai, oppos)
                end
            end
        end
        update.read[] && begin
            @debug "sync pos: update already read" ai = raw(ai) pside
            overwrite || return pos
        end
    end

    if update.closed[]
        if !isdust(ai, _ccxtposprice(ai, resp), pside) && isfinite(cash(pos))
            @warn "sync pos: cash expected to be (close to) zero, found" cash = cash(
                ai, pside
            ) cash(ai, pside).precision
        end
        update.read[] = true
        reset!(pos)
        @debug "sync pos: closed flag set, reset"
        return pos
    end
    this_timestamp = update.date
    if this_timestamp <= timestamp(pos)
        @debug "sync pos: position timestamp not newer" timestamp(pos) this_timestamp overwrite f = @caller
        overwrite || return pos
    end

    # Margin/hedged mode are immutable so just check for mismatch
    let mm = resp_position_margin_mode(resp, eid)
        pyisnone(mm) ||
            pyeq(Bool, mm, _ccxtmarginmode(pos)) ||
            @warn "sync pos: position margin mode mismatch local: $(marginmode(pos)), remote: $(mm)"
    end

    # resp cash, (always positive for longs, or always negative for shorts)
    let rv = islong(pos) ? positive(amount) : negative(amount)
        isapprox(ai, cash(pos), rv, Val(:amount)) ||
            @warn_unsynced "amount" abs(cash(pos)) amount
        cash!(pos, rv)
    end
    # If the respd amount is "dust" the position should be considered closed, and to be reset
    pos_price = _ccxtposprice(ai, resp)
    if isdust(ai, pos_price, pside)
        update.read[] = true
        reset!(pos)
        @debug "sync pos: amount is dust, reset" isopen(ai, p)
        return pos
    end
    @debug "sync pos: syncing" date = timestamp(pos) ai = raw(ai) side = pside
    pos.status[] = PositionOpen()
    let lap = ai.lastpos
        if isnothing(lap[]) || timestamp(ai, opposite(pside)) <= this_timestamp
            lap[] = pos
        end
    end
    function dowarn(what, val)
        @warn "sync pos: unable to sync $what from $(nameof(exchange(ai))), got $val"
    end
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
        @debug "sync pos: local committment" comm ai = raw(ai) side = pside
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
    @assert ntl > ZERO "sync pos: notional can't be zero"

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
    adt = max(zero(DFT), coll - (mrg + 2(mrg * maxfees(ai))))
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
        "sync pos: ($(raw(ai))) $whata ($(a)) can't be higher than $whatb ($(b))"
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
        "committment", "cash", abs(committed(pos)), abs(cash(pos))
    )
    @assert leverage(pos) <= maxleverage(pos) higherwarn(
        "leverage", "max leverage", leverage(pos), maxleverage(pos)
    )
    @assert pos.min_size <= notional(pos) higherwarn(
        "min size", "notional", pos.min_size, notional(pos)
    )
    timestamp!(pos, this_timestamp)
    @debug "sync pos: synced" date = this_timestamp amount = resp_position_contracts(
        update.resp, eid
    ) ai = raw(ai) f = @caller
    update.read[] = true
    return pos
end

function live_sync_position!(
    s::LiveStrategy,
    ai::MarginInstance,
    pos::ByPos;
    force=true,
    since=nothing,
    waitfor=Second(5),
    kwargs...,
)
    update = live_position(s, ai, pos; force, since, waitfor)
    isnothing(update) || live_sync_position!(s, ai, pos, update; kwargs...)
end

function live_sync_position!(s::LiveStrategy, ai::MarginInstance; kwargs...)
    @sync for pos in (Long, Short)
        @async live_sync_position!(s, ai, pos; kwargs...)
    end
end

function live_sync_cash!(
    s::MarginStrategy{Live},
    ai,
    bp::ByPos=@something(posside(ai), get_position_side(s, ai));
    since=nothing,
    waitfor=Second(5),
    kwargs...,
)
    side = posside(bp)
    pup = live_position(s, ai, side; since, force=true, waitfor)
    if isnothing(pup)
        @warn "sync cash: resetting (both) position cash (not found)" ai = raw(ai)
        reset!(ai, Long())
        reset!(ai, Short())
    elseif pup.closed[]
        @warn "sync cash: resetting position cash (closed)" ai = raw(ai) side
        reset!(ai, side)
    elseif isnothing(since) || (timestamp(ai, side) < since && pup.date >= since)
        live_sync_position!(s, ai, side, pup; kwargs...)
    else
        @error "Could not update position cash" last_updated = timestamp(ai, side) since pup.date ai = raw(
            ai
        ) side pup.closed[] pup.read[]
    end
    position(ai, bp)
end

@doc """ Asset balance is the position of the asset when margin is involved.

"""
function live_sync_universe_cash!(s::MarginStrategy{Live}; overwrite=true, kwargs...)
    long, short = get_positions(s)
    default_date = now()
    function dosync(ai, side, dict)
        pup = @something get(dict, raw(ai), nothing) live_position(s, ai, side; force=true) missing
        if ismissing(pup)
            @debug "sync uni: resetting position (no update)" ai = raw(ai) side
            reset!(ai, side)
        else
            live_sync_position!(s, ai, side, pup; overwrite, kwargs...)
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
