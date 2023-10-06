using .Instances: MarginInstance, raw, cash, cash!
using .Python:
    PyException,
    pyisinstance,
    pybuiltins,
    @pystr,
    @pyconst,
    pytryfloat,
    pytruth,
    pyconvert,
    pyeq
using Watchers: buffer
using .Python.PythonCall: pyisTrue, pyeq, Py, pyisnone
using .Misc.Lang: @lget!, Option, @caller
using .Executors.OrderTypes: ByPos
using .Executors: committed, marginmode, update_leverage!, liqprice!, update_maintenance!
using .Executors.Instruments: qc, bc
using .Executors.Instruments.Derivatives: sc
using .Instances:
    PositionOpen,
    PositionClose,
    position,
    reset!,
    isdust,
    liqprice!,
    entryprice!,
    entryprice,
    maintenance,
    maintenance!,
    posside,
    mmr,
    margin,
    collateral,
    margin!,
    initial!,
    additional!,
    addmargin!,
    liqprice,
    timestamp,
    timestamp!,
    maxleverage,
    notional,
    notional!,
    tier!
using Base: negate

_ispossym(py, sym, eid::EIDType) = pyeq(Bool, resp_position_symbol(py, eid), @pystr(sym))

function _handle_pos_resp(resp, ai, side)
    sym = raw(ai)
    eid = exchangeid(ai)
    if resp isa PyException
        @debug "force fetch pos: error $sym($side)" resp
        return nothing
    elseif islist(resp)
        if isempty(resp)
            @debug "force fetch pos: returned an empty list $sym($side)"
            return resp
        else
            for this in resp
                @debug "force fetch pos: list el" resp_position_timestamp(this, eid) resp_position_contracts(
                    this, eid
                ) side _ccxtposside(this, eid) issym = _ispossym(this, sym, eid)
                if _ccxtposside(this, eid) == side && _ispossym(this, sym, eid)
                    @deassert !isnothing(this) && isdict(this)
                    return this
                end
            end
            @ifdebug if isopen(ai)
                @debug "force fetch pos: did not find the requested symbol $sym($side)" resp
            end
            return nothing
        end
    elseif isdict(resp) && _ccxtposside(resp, eid) == side && _ispossym(resp, sym, eid)
        return resp
    else
        @debug "force fetch pos: unhandled response $sym($side)" resp
        return nothing
    end
end

function _force_fetchpos(s, ai, side; fallback_kwargs)
    w = positions_watcher(s)
    @debug "force fetch pos: locking w" islocked(w) ai = raw(ai) f = @caller 7
    waslocked = islocked(w)
    @lock w begin
        waslocked && return nothing
        time = now()
        resp = fetch_positions(s, ai; side, fallback_kwargs...)
        pos = _handle_pos_resp(resp, ai, side)
        pushnew!(
            w,
            if islist(pos)
                pos
            else
                pylist((pos,))
            end,
            time,
        )
        process!(w; sym=raw(ai))
    end
end

function live_position(
    s::LiveStrategy,
    ai,
    side=get_position_side(s, ai);
    fallback_kwargs=(),
    since=nothing,
    force=false,
    waitfor=Second(5),
)
    pup = get_positions(s, ai, side)::Option{PositionUpdate7}

    @ifdebug force && @debug "live pos: force fetching position" watcher_locked = islocked(
        positions_watcher(s)
    ) maxlog = 1
    if force &&
        !islocked(positions_watcher(s)) &&
        (
            isnothing(pup) || (
                !isnothing(since) &&
                let time = @something(
                        pytodate(pup.resp, exchangeid(ai)), timestamp(ai, side)
                    )
                    time < since
                end
            )
        )
        _force_fetchpos(s, ai, side; fallback_kwargs)
        pup = get_positions(s, ai, side)
    end
    isnothing(since) ||
        isnothing(pup) ||
        begin
            if waitforpos(s, ai, side; since, force, waitfor)
            elseif force # try one last time to force fetch
                @debug "live pos: last force fetch"
                _force_fetchpos(s, ai, side; fallback_kwargs)
            end
            pup = get_positions(s, ai, side)
            if isnothing(pup) || pup.date < since
                @error "live pos: last force fetch failed" date =
                    isnothing(pup) ? nothing : pup.date since force pup.read[] pup.closed[] f = @caller
                return nothing
            end
        end
    return pup
end

function _pup(s, ai, args...; kwargs...)
    pup = live_position(s, ai, args...; kwargs...)
    if isnothing(pup)
        @debug "live pup: " f = @caller
    else
        @debug "live pup: " pup.read[] pup.closed[] f = @caller
    end
    pup
end

function live_contracts(s::LiveStrategy, ai, args...; kwargs...)
    pup = _pup(s, ai, args...; kwargs...)
    if isnothing(pup) || pup.closed[]
        ZERO
    else
        amt = resp_position_contracts(pup.resp, exchangeid(ai))
        if isshort(ai)
            -amt
        else
            amt
        end
    end
end

function live_notional(s::LiveStrategy, ai, args...; kwargs...)
    pup = _pup(s, ai, args...; kwargs...)
    if isnothing(pup) || pup.closed[]
        ZERO
    else
        abs(resp_position_notional(pup.resp, exchangeid(ai)))
    end
end

_ccxtmmr(lp::Py, pos, eid) =
    let v = resp_position_mmr(lp, eid)
        if v > ZERO
            v
        else
            mmr(pos)
        end
    end

const Pos = NamedTuple(
    Symbol(f) => f for f in (
        "liquidationPrice",
        "initialMargin",
        "maintenanceMargin",
        "collateral",
        "entryPrice",
        "timestamp",
        "datetime",
        "lastUpdateTimestamp",
        "additionalMargin",
        "notional",
        "contracts",
        "symbol",
        "unrealizedPnl",
        "leverage",
        "id",
        "contractSize",
        "markPrice",
        "lastPrice",
        "marginMode",
        "marginRatio",
        "side",
        "hedged",
        "percentage",
    )
)

_ccxtposside(::ByPos{Long}) = "long"
_ccxtposside(::ByPos{Short}) = "short"
function _ccxtisshort(v::Py, eid::EIDType)
    pyeq(Bool, resp_position_side(v, eid), @pyconst("short"))
end
_ccxtislong(v::Py, eid::EIDType) = pyeq(Bool, resp_position_side(v, eid), @pyconst("long"))
_ccxtposside(v::Py, eid::EIDType) =
    if _ccxtislong(v, eid)
        Long()
    elseif _ccxtisshort(v, eid)
        Short()
    else
        _ccxtpnlside(v, eid)
    end
function _ccxtposside(::MarginStrategy{Live}, v::Py, eid::EIDType; def=Long())
    let side = resp_order_side(v, eid)
        if pyeq(Bool, side, @pyconst("sell"))
            Short()
        elseif pyeq(Bool, side, @pyconst("buy"))
            Long()
        else
            @warn "Side value not found, defaulting to $def" resp = v
            def
        end
    end
end
_ccxtposside(::NoMarginStrategy{Live}, args...; kwargs...) = Long()
function _ccxtposprice(ai, update)
    eid = exchangeid(ai)
    lp = resp_position_lastprice(update, eid)
    if lp <= zero(DFT)
        lp = resp_position_markprice(update, eid)
        if lp <= zero(DFT)
            lastprice(ai)
        else
            lp
        end
    else
        lp
    end
end

function _ccxtpnlside(update, eid::EIDType)
    unpnl = resp_position_unpnl(update, eid)
    liqprice = resp_position_liqprice(update, eid)
    eprice = resp_position_entryprice(update, eid)
    ifelse(unpnl >= ZERO && liqprice < eprice, Long(), Short())
end

function posside_fromccxt(update, eid::EIDType, p::Option{ByPos}=nothing)
    ccxt_side = resp_position_side(update, eid)
    if pyisnone(ccxt_side)
        if isnothing(p)
            @debug "ccxt posside: side not provided, inferring from position state" @caller
            _ccxtpnlside(update, eid)
        else
            posside(p)
        end
    else
        let side_str = ccxt_side.lower()
            if pyeq(Bool, side_str, @pyconst("short"))
                Short()
            elseif pyeq(Bool, side_str, @pyconst("long"))
                Long()
            else
                @debug "ccxt posside: side flag not valid (non open pos?), inferring from position state" side_str resp_position_contracts(
                    update, eid
                ) f = @caller
                side = _ccxtpnlside(update, eid)
                @debug "ccxt posside: inferred" side
                side
            end
        end
    end
end

function _ccxt_isposopen(pos::Py, eid::EIDType)
    c = resp_position_contracts(pos, eid) > ZERO
    i = !iszero(resp_position_initial_margin(pos, eid))
    n = !iszero(resp_position_notional(pos, eid))
    l = !iszero(resp_position_liqprice(pos, eid))
    if c && !(i && n && l)
        @warn "Position state dirty, contracts: $c > 0, but margin: $i, notional: $n, liqprice: $l"
    end
    c
end

function _ccxt_isposclosed(pos::Py, eid::EIDType)
    c = iszero(resp_position_contracts(pos, eid))
    i = !iszero(resp_position_initial_margin(pos, eid))
    n = !iszero(resp_position_notional(pos, eid))
    p = !iszero(resp_position_unpnl(pos, eid))
    l = !iszero(resp_position_liqprice(pos, eid))
    if c && (i || n || p || l)
        @warn "Position state dirty, contracts: $c == 0, but margin: $i, notional: $n, pnl: $p, liqprice: $l"
    end
    c
end

function waitforpos(
    s::LiveStrategy,
    ai,
    bp::ByPos=posside(ai);
    since::Option{DateTime}=nothing,
    waitfor=Second(5),
    force=true,
    fallback_kwargs=(),
)
    pos = position(ai, bp)
    eid = exchangeid(ai)
    timeout = Millisecond(waitfor).value
    slept = 0
    minsleep = Millisecond(max(Second(1), waitfor))
    pup = get_positions(s, ai, bp)
    if isnothing(pup) && force
        while true
            pup = get_positions(s, ai, bp)
            isnothing(pup) || break
            slept < timeout || begin
                @debug "wait for pos: timedout (position not found)" ai = raw(ai) side = bp f = @caller
                return false
            end
            sleep(minsleep)
            slept += minsleep.value
            _force_fetchpos(s, ai, bp; fallback_kwargs)
        end
    end
    prev_timestamp = pup.date
    @debug "wait for pos" prev_timestamp since resp_position_contracts(pup.resp, eid) f = @caller
    prev_since = @something since typemin(DateTime)
    if prev_timestamp >= prev_since
        return true
    end
    this_timestamp = prev_timestamp - Millisecond(1)
    prev_closed = isnothing(pup) || pup.closed[]
    @debug "wait for pos: waiting" side = bp timeout = timeout read = pup.read[] prev_closed

    while true
        slept += waitforcond(pup.notify, timeout - slept)
        this_timestamp = pup.date
        if this_timestamp >= prev_timestamp >= prev_since
            since
            @debug "wait for pos: up to date " prev_timestamp this_timestamp resp_position_contracts(
                pup.resp, eid
            ) pup.closed[]
            return true
        else
            this_closed = pup.closed[]
            if this_closed && this_closed != prev_closed
                @debug "wait for pos: closed"
                return true # Position was closed but timestamp wasn't updated
            else
                prev_closed = this_closed
            end
            @debug "wait for pos:" time_left = Millisecond(timeout - slept) prev_timestamp current_timestamp =
                pup.date side = posside(bp) ai = raw(ai)
        end
        slept < timeout || begin
            @debug "wait for pos: timedout" ai = raw(ai) side = bp f = @caller
            return false
        end
    end
end

function waitforpos(s::LiveStrategy, ai, bp::ByPos, ::Val{:local}; waitfor=Second(5))
    pos = position(ai, bp)
    eid = exchangeid(ai)
    this_timestmap = prev_timestamp = timestamp(pos)
    slept = 0
    timeout = Millisecond(waitfor).value
    while slept < timeout
        this_timestamp = timestamp(pos)
        this_timestamp != prev_timestamp && break
    end
end

function waitposclose(
    s::LiveStrategy, ai, bp::ByPos=posside(ai); waitfor=Second(5), sync=true
)
    eid = exchangeid(ai)
    slept = 0
    timeout = Millisecond(waitfor).value
    update = get_positions(s, ai, bp)
    last_sync = false
    while true
        if update.closed[] ||
            iszero(resp_position_contracts(update.resp, eid)) ||
            isempty(resp_position_side(update.resp, eid))
            update.read[] || live_sync_position!(s, ai, bp, update)
            @deassert !isopen(ai, bp)
            return true
        elseif slept >= timeout
            if last_sync || !sync
                @debug "wait pos close: timedout" ai = raw(ai) bp last_sync f = @caller(5)
                return false
            else
                @deassert sync
                update = live_position(s, ai, bp; force=true)
                @debug "wait pos close: last sync" ai = raw(ai) bp date =
                    isnothing(update) ? nothing : update.date closed =
                    isnothing(update) ? nothing : update.closed[] amount =
                    isnothing(update) ? nothing : resp_position_contracts(update.resp, eid)
                last_sync = true
                continue
            end
        end
        slept += waitforcond(update.notify, timeout - slept)
        update = get_positions(s, ai, bp)
        @debug "wait pos close: waiting" ai = raw(ai) side = posside(bp) closed = update.closed[] contracts = resp_position_contracts(
            update.resp, eid
        ) slept timeout
    end
end
