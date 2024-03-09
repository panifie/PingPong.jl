@doc """ Logs a warning if a position is unsynced

$(TYPEDSIGNATURES)

This macro logs a warning if a position is not in sync between local and remote states.
The warning includes the provided message, position details, and the instance and strategy names.

"""
macro warn_unsynced(what, loc, rem, msg="unsynced")
    ex = quote
        (
            wasopen &&
            @warn "Position $($msg) ($($what)) local: $($loc), remote: $($rem) $this_timestamp ($(raw(ai))@$(nameof(s)))"
        )
    end
    esc(ex)
end

@doc """ Synchronizes the live position.

$(TYPEDSIGNATURES)

This function synchronizes the live position with the actual position in the market.
It does this by checking various parameters such as the amount, entry price, leverage, notional, and margins.
If there are discrepancies, it adjusts the live position accordingly.
For instance, if the amount in the live position does not match the actual amount, it updates the live position's amount.
It also checks for conditions like whether the position is open or closed, and if the position is hedged or not.
If the position is closed, it resets the position. If the position is open, it updates the timestamp of the position.
`forced_side` auto closes the opposite position side when `true.

!!! warn
    This functions should be called with the `update` lock held.

"""
function _live_sync_position!(
    s::LiveStrategy,
    ai::MarginInstance,
    p::Option{ByPos},
    update::PositionTuple;
    amount=resp_position_contracts(update.resp, exchangeid(ai)),
    ep_in=resp_position_entryprice(update.resp, exchangeid(ai)),
    commits=true,
    skipchecks=false,
    overwrite=false,
    forced_side=false,
    waitfor=Second(5),
)
    let queue = asset_queue(s, ai)
        if queue[] > 1
            @debug "sync pos: events queue is congested" _module = LogPosSync queue[]
            return nothing
        end
    end
    eid = exchangeid(ai)
    resp = update.resp
    pside = posside_fromccxt(resp, eid, p)
    pos = position(ai, pside)
    wasopen = isopen(pos) # by macro warn_unsynced

    # check hedged mode
    if !resp_position_hedged(resp, eid) == ishedged(pos)
        @warn "sync pos: hedged mode mismatch" loc = ishedged(pos)
        @assert marginmode!(exchange(ai), _ccxtmarginmode(ai), raw(ai), hedged=ishedged(pos), lev=leverage(pos)) "failed to set hedged mode on exchange"
    end
    if !skipchecks
        if !ishedged(pos) && isopen(opposite(ai, pside)) && !update.closed[]
            let oppos = opposite(pside),
                live_pup = let lp(force) = live_position(s, ai, oppos; since=update.date, force)
                    @something lp(false) lp(true)
                end

                if !isnothing(live_pup)
                    live_pos = live_pup.resp
                    amount = resp_position_contracts(live_pos, eid)
                    if amount > ZERO
                        if wasopen
                            @warn "sync pos: double position open in oneway mode." oppos cash(
                                ai, oppos
                            ) raw(ai) nameof(s) f = @caller
                        end
                        if forced_side
                            pong!(s, ai, oppos, now(), PositionClose(); amount, waitfor)
                            oppos_pos = position(ai, oppos)
                            if isopen(oppos_pos)
                                return pos
                            end
                        elseif live_pup.date > update.date
                            update.closed[] = true
                        else
                            return pos
                        end
                    end
                else
                    @debug "sync pos: resetting opposite position" _module = LogPosSync ai = raw(ai) oppos
                    reset!(position(ai, oppos))
                end

            end
        end
    end

    update.read[] && begin
        @debug "sync pos: update already read" _module = LogPosSync ai = raw(ai) pside overwrite # resp f = @caller
        if !overwrite
            return pos
        end
    end

    if update.closed[]
        if !isdust(ai, _ccxtposprice(ai, resp), pside) && isfinite(cash(pos))
            @warn "sync pos: cash expected to be (close to) zero, found" cash = cash(
                ai, pside
            ) cash(ai, pside).precision
        end
        update.read[] = true
        reset!(pos) # if not full reset at least cash/committed
        timestamp!(pos, update.date)
        @debug "sync pos: closed flag set, reset" _module = LogPosSync ai = raw(ai)
        return pos
    end

    this_timestamp = update.date
    if this_timestamp < timestamp(pos)
        @debug "sync pos: position timestamp not newer" _module = LogPosSync timestamp(pos) this_timestamp overwrite f = @caller
        return pos
    end

    # Margin/hedged mode are immutable so just check for mismatch
    let mm = resp_position_margin_mode(resp, eid)
        if pyisnone(mm) || pyeq(Bool, mm, _ccxtmarginmode(pos))
        else
            @warn "sync pos: position margin mode mismatch" ai = raw(ai) loc = marginmode(pos) rem = mm
            @assert marginmode!(exchange(ai), _ccxtmarginmode(ai), raw(ai), hedged=ishedged(pos), lev=leverage(pos)) "sync pos: failed to set margin mode on exchange"
        end
    end

    # resp cash, (always positive for longs, or always negative for shorts)
    let rv = islong(pos) ? positive(amount) : negative(amount)
        @debug "sync pos: amount" _module = LogPosSync rv posside(pos)
        if !isapprox(ai, cash(pos), rv, Val(:amount))
            @warn_unsynced "amount" posside(pos) abs(cash(pos)) amount
        end
        cash!(pos, rv)
    end
    # If the respd amount is "dust" the position should be considered closed, and to be reset
    pos_price = _ccxtposprice(ai, resp)
    if isdust(ai, pos_price, pside)
        update.read[] = true
        reset!(pos)
        @debug "sync pos: amount is dust, reset" _module = LogPosSync isopen(ai, p) cash(ai) resp
        return pos
    end
    @debug "sync pos: syncing" _module = LogPosSync date = timestamp(pos) ai = raw(ai) side = pside
    pos.status[] = PositionOpen()
    let lap = ai.lastpos
        if isnothing(lap[]) || timestamp(ai, opposite(pside)) <= this_timestamp
            lap[] = pos
        end
    end
    function dowarn(what, val)
        @debug what resp _module = LogPosSync
        @warn "sync pos: unable to sync $what from $(nameof(exchange(ai))), got $val"
    end
    # price is always positive
    ep = pytofloat(ep_in)
    ep = if ep > zero(DFT)
        if !isapprox(entryprice(pos), ep; rtol=1e-3)
            @warn_unsynced "entryprice" entryprice(pos) ep
        end
        entryprice!(pos, ep)
        ep
    else
        entryprice!(pos, pos_price)
        dowarn("entry price", ep)
        pos_price
    end
    commits && let comm = committed(s, ai, pside)
        @debug "sync pos: local committment" _module = LogPosSync comm ai = raw(ai) side = pside
        if !isapprox(committed(pos).value, comm)
            commit!(pos, comm)
        end
    end

    lev = resp_position_leverage(resp, eid)
    if lev > zero(DFT)
        if !isapprox(leverage(pos), lev; atol=1e-2)
            @warn_unsynced "leverage" leverage(pos) lev
        end
        leverage!(pos, lev)
    else
        dowarn("leverage", lev)
        lev = one(DFT)
    end
    ntl = let v = resp_position_notional(resp, eid)
        if v > zero(DFT)
            ntl = notional(pos)
            if !isapprox(ntl, v; rtol=0.05)
                @warn_unsynced "notional" ntl v "error too high"
            end
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
            if !isapprox(liqprice(pos), lqp; rtol=0.05)
                @warn_unsynced "liqprice" liqprice(pos) lqp "error too high"
            end
            liqprice!(pos, lqp)
            true
        end

    mrg = resp_position_initial_margin(resp, eid)
    coll = resp_position_collateral(resp, eid)
    adt = max(zero(DFT), coll - (mrg + 2(mrg * maxfees(ai))))
    mrg_set =
        mrg > zero(DFT) && begin
            if !isapprox(mrg, margin(pos); rtol=1e-2)
                @warn_unsynced "initial margin" margin(pos) mrg
            end
            initial!(pos, mrg)
            if !isapprox(adt, additional(pos); rtol=1e-2)
                @warn_unsynced "additional margin" additional(pos) adt
            end
            additional!(pos, adt)
            true
        end
    mm = resp_position_maintenance_margin(resp, eid)
    mm_set =
        mm > zero(DFT) && begin
            if !isapprox(mm, maintenance(pos); rtol=0.05)
                @warn_unsynced "maintenance margin" maintenance(pos) mm
            end
            maintenance!(pos, mm)
            true
        end
    # Since we don't know if the exchange supports all position fields
    # try to emulate the ones not supported based on what is available
    _margin!() = begin
        margin!(pos; ntl, lev)
        additional!(pos, max(zero(DFT), coll - margin(pos)))
    end

    if !liqprice_set
        liqprice!(
            pos,
            liqprice(
                pside, ep, lev, _ccxtmmr(resp, pos, eid); additional=adt, notional=ntl
            ),
        )
    end
    if !mrg_set
        _margin!()
    end
    if !mm_set
        update_maintenance!(pos; mmr=_ccxtmmr(resp, pos, eid))
    end
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
    if pos.min_size <= notional(pos)
        @assert abs(cash(pos)) >= ai.limits.amount.min higherwarn(
            "min size", "notional", pos.min_size, notional(pos)
        )
    end
    timestamp!(pos, this_timestamp)
    @debug "sync pos: synced" _module = LogPosSync date = this_timestamp amount = resp_position_contracts(
        update.resp, eid
    ) ai = raw(ai) posside(ai) cash(ai) isopen(ai, Long()) isopen(ai, Short()) f = @caller
    update.read[] = true
    return pos
end

function live_sync_position!(s::LiveStrategy, ai::MarginInstance, pos, update; kwargs...)
    @debug "sync pos: locking ai" _module = LogPosSync ai = raw(ai)
    @lock ai @lock update.notify begin
        _live_sync_position!(s, ai, pos, update; kwargs...)
        if isopen(ai) || hasorders(s, ai)
            push!(s.holdings, ai)
        else
            delete!(s.holdings, ai)
        end
    end
end

function live_sync_position!(
    s::LiveStrategy,
    ai::MarginInstance,
    pos::ByPos;
    force=false,
    since=nothing,
    waitfor=Second(5),
    kwargs...,
)
    update = live_position(s, ai, pos; force, since, waitfor)
    if isnothing(update)
        @warn "live sync pos: no update found" ai pos force since
    else
        live_sync_position!(s, ai, pos, update; kwargs...)
    end
end

function live_sync_position!(s::LiveStrategy, ai::HedgedInstance; kwargs...)
    @sync for pos in (Long, Short)
        @async live_sync_position!(s, ai, pos; kwargs...)
    end
end

function live_sync_position!(s::LiveStrategy, ai::MarginInstance; kwargs...)
    live_sync_position!(s, ai, get_position_side(s, ai); kwargs...)
end

@doc """ Synchronizes the cash position in a live trading strategy.

$(TYPEDSIGNATURES)

This function synchronizes the cash position of a given asset in a live trading strategy.
It checks the current position status and updates it accordingly.
If the position is closed, it resets the position.
If the position is open, it synchronizes the position with the market.
The function locks the asset instance during the update to prevent race conditions.

"""
function live_sync_cash!(
    s::MarginStrategy{Live},
    ai,
    bp::ByPos=@something(posside(ai), get_position_side(s, ai));
    since=nothing,
    waitfor=Second(5),
    force=false,
    kwargs...,
)
    side = posside(bp)
    pup = live_position(s, ai, side; since, force, waitfor)
    @lock ai if isnothing(pup)
        @warn "sync cash: resetting (both) position cash (not found)" ai = raw(ai)
        reset!(ai, bp)
    elseif pup.closed[]
        @info "sync cash: resetting position cash (closed)" ai = raw(ai) side
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

@doc """ Synchronizes the cash position for all assets in a live trading strategy.

$(TYPEDSIGNATURES)

This function synchronizes the cash position for all assets in a live trading strategy.
It iterates over each asset in the universe and synchronizes its cash position.
The function uses a helper function `dosync` to perform the synchronization for each asset.
The synchronization process is performed concurrently for efficiency.

"""
function live_sync_universe_cash!(s::MarginStrategy{Live}; overwrite=false, force=false, kwargs...)
    if force # wait for position watcher
        let w = positions_watcher(s)
            while isempty(w.buffer)
                @debug "sync uni cash: waiting for position data" _module = LogUniSync
                if !wait(w)
                    break
                end
            end
        end
    end
    long, short, _ = get_positions(s)
    default_date = now()
    function dosync(ai, side, dict)
        @debug "sync universe cash:" _module = LogUniSync ai = raw(ai) get(dict, raw(ai), nothing)
        pup = @something get(dict, raw(ai), nothing) live_position(s, ai, side; force, synced=force) missing
        if ismissing(pup)
            @debug "sync uni: resetting position (no update)" _module = LogUniSync ai = raw(ai) side
            reset!(ai, side)
        else
            @debug "sync uni: sync pos" _module = LogUniSync ai = raw(ai) side
            live_sync_position!(s, ai, side, pup; overwrite, kwargs...)
        end
    end
    if force
        @sync for ai in s.universe
            @async begin
                @sync begin
                    if ishedged(ai)
                        @async @lock ai dosync(ai, Long(), long)
                        @async @lock ai dosync(ai, Short(), short)
                    else
                        @async @lock ai begin
                            dosync(ai, Long(), long)
                            dosync(ai, Short(), short)
                        end
                    end
                end
                set_active_position!(ai; default_date)
            end
        end
    else
        for ai in s.universe
            dosync(ai, Long(), long)
            dosync(ai, Short(), short)
            set_active_position!(ai; default_date)
        end
    end
end
