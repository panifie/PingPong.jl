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

function _force_fetch(s, ai, sym, side; fallback_kwargs)
    resp = fetch_positions(s, ai; fallback_kwargs...)
    eid = exchangeid(ai)
    pos = if resp isa PyException
        return nothing
    elseif islist(resp)
        if isempty(resp)
            return nothing
        else
            for this in resp
                if _ccxtposside(this, eid) == side && _ispossym(this, sym, eid)
                    return this
                end
            end
        end
    end
end

function _isold(snap, since, eid)
    !isnothing(since) && @something(pytodate(snap, eid), since) < since
end
function live_position(
    s::LiveStrategy,
    ai,
    side=_optposside(ai);
    fallback_kwargs=(),
    since=nothing,
    force=false,
)
    data = get_positions(s, side)
    sym = raw(ai)
    eid = exchangeid(ai)
    tup = get(data, sym, nothing)
    if isnothing(tup) && force
        resp = _force_fetch(s, ai, sym, side; fallback_kwargs)
        if isdict(resp) && _ispossym(resp, sym, eid)
            date = @something pytodate(resp, eid) now()
            tup = data[sym] = _posupdate(date, resp)
        end
    end
    while !isnothing(tup) && _isold(tup.resp, since, eid)
        safewait(tup.notify)
        tup = get(data, sym, nothing)
    end
    return tup
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
            @warn "Position side not provided, inferring from position state"
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
                @warn "Position side flag not valid, inferring from position state"
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
