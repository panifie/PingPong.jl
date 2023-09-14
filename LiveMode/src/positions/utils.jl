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
using .Misc.Lang: @lget!, Option
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
_optposside(ai) =
    let p = position(ai)
        isnothing(p) ? nothing : posside(p)
    end

function _handle_pos_resp(resp, ai, side)
    sym = raw(ai)
    eid = exchangeid(ai)
    if resp isa PyException
        @debug "Force fetch position error $sym($side)" resp
        return nothing
    elseif islist(resp)
        if isempty(resp)
            @debug "Force fetch position returned an empty list $sym($side)"
            return nothing
        else
            for this in resp
                if _ccxtposside(this, eid) == side && _ispossym(this, sym, eid)
                    return this
                end
            end
            @debug "Force fetch position did not find the requested symbol $sym($side)" resp
            return nothing
        end
    elseif isdict(resp) && _ccxtposside(resp, eid) == side && _ispossym(resp, sym, eid)
        return resp
    else
        @debug "Force fetch position unhandled response $sym($side)" resp
        return nothing
    end
end

function _force_fetchpos(s, ai, side; fallback_kwargs)
    w = positions_watcher(s)
    @lock w begin
        resp = fetch_positions(s, ai; fallback_kwargs...)
        pos = _handle_pos_resp(resp, ai, side)
        if islist(pos)
            pushnew!(w, pos)
        elseif isdict(pos)
            pushnew!(w, pylist((pos,)))
        end
        process!(w)
        return pos
    end
end

function live_position(
    s::LiveStrategy,
    ai,
    side=_optposside(ai);
    fallback_kwargs=(),
    since=nothing,
    force=false,
    waitfor=Second(10),
)
    pup = get_positions(s, ai, side)::Option{PositionUpdate7}

    @ifdebug force && @debug "Force fetching position" watcher_locked = islocked(
        positions_watcher(s)
    ) maxlog = 1
    if force &&
        !islocked(positions_watcher(s)) &&
        (
            isnothing(since) ||
            let time = @something(pytodate(pup.resp, exchangeid(ai)), timestamp(ai, side))
                time < since
            end
        )
        _force_fetchpos(s, ai, side; fallback_kwargs)
    end
    force && isnothing(pup) && begin
        _force_fetchpos(s, ai, side; fallback_kwargs)
        pup = get_positions(s, ai, side)
    end
    isnothing(since) || isnothing(pup) || waitforpos(s, ai, side; since, waitfor)
    return pup
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
function _ccxtposside(v::Py, eid::EIDType, ::Val{:order}; def=Long())
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
            @debug "Position side not provided, inferring from position state"
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
                @debug "Position side flag not valid (non open pos?), inferring from position state"
                # @debug "Resp of invalid position flag" update
                _ccxtpnlside(update, eid)
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
    waitfor=Second(1),
)
    pos = position(ai, bp)
    eid = exchangeid(ai)
    update = get_positions(s, ai, bp)
    prev_timestamp = @something pytodate(update.resp, eid) timestamp(pos)
    @debug "Waiting for position " prev_timestamp >= since prev_timestamp since
    isnothing(since) || if prev_timestamp >= since
        return prev_timestamp
    end
    this_timestamp = prev_timestamp - Millisecond(1)
    timeout = Millisecond(waitfor).value
    slept = 0
    @debug "Waiting for position " side = bp timeout = timeout red = update.read[] closed = update.closed[]

    while slept < timeout
        slept += waitforcond(update.notify, timeout - slept)
        this_timestamp = @something pytodate(update.resp, eid) prev_timestamp
        if this_timestamp > prev_timestamp
            break
        else
            @debug "Waiting $(Millisecond(timeout - slept)) for a position update more recent than \
                    $prev_timestamp (current: $(pytodate(update.resp, eid))) ($(raw(ai))$(posside(ai)))"
        end
    end
    @ifdebug slept >= timeout &&
        @warn "Position fetch since $(prev_timestamp) timed out $(raw(ai))@$(nameof(s))"
    return this_timestamp
end
