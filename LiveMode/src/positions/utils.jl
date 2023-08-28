using .Instances: MarginInstance, raw, cash, cash!
using .Python:
    PyException, pyisinstance, pybuiltins, @pystr, @pyconst, pytryfloat, pytruth, pyconvert, pyeq
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

_issym(py, sym) = pyeq(Bool, get_py(py, "symbol"), @pystr(sym))
_optposside(ai) =
    let p = position(ai)
        isnothing(p) ? nothing : posside(p)
    end

function _force_fetch(s, ai, sym, side; fallback_kwargs)
    resp = fetch_positions(s, ai; fallback_kwargs...)
    pos = if resp isa PyException
        return nothing
    elseif islist(resp)
        if isempty(resp)
            return nothing
        else
            for this in resp
                if _ccxtposside(this) == side && _issym(this, sym)
                    return this
                end
            end
        end
    end
end

_isold(snap, since) = !isnothing(since) && @something(pytodate(snap), since) < since
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
    tup = get(data, sym, nothing)
    if isnothing(tup) && force
        pos = _force_fetch(s, ai, sym, side; fallback_kwargs)
        if isdict(pos) && _issym(pos, sym)
            get(positions_watcher(s).attrs, :keep_info, false) || _deletek(pos, "info")
            date = @something pytodate(pos) now()
            tup = data[sym] = (date, notify=Base.Threads.Condition(), pos)
        end
    end
    while !isnothing(tup) && _isold(tup.pos, since)
        safewait(tup.notify)
        tup = get(data, sym, nothing)
    end
    tup isa NamedTuple ? tup.pos : nothing
end

pytostring(v) = pytruth(v) ? string(v) : ""
get_py(v::Py, k) = get(v, @pystr(k), pybuiltins.None)
get_py(v::Py, k, def) = get(v, @pystr(k), def)
get_py(v::Py, def, keys::Vararg{String}) = begin
    for k in keys
        ans = get_py(v, k)
        pyisnone(ans) || (return ans)
    end
    return def
end
get_string(v::Py, k) = get_py(v, k) |> pytostring
get_float(v::Py, k) = get_py(v, k) |> pytofloat
get_bool(v::Py, k) = get_py(v, k) |> pytruth
get_time(v::Py, k) =
    let d = get_py(v, k)
        @something pyconvert(Option{DateTime}, d) now()
    end
live_amount(lp::Py) = get_float(lp, "contracts")
live_entryprice(lp::Py) = get_float(lp, "entryPrice")
live_mmr(lp::Py, pos) =
    let v = get_float(lp, "maintenanceMarginPercentage")
        if v > ZERO
            v
        else
            mmr(pos)
        end
    end

const Pos =
    PosFields = NamedTuple(
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

live_side(v::Py) = get_py(v, "side", @pyconst("")).lower()
_ccxtposside(::ByPos{Long}) = "long"
_ccxtposside(::ByPos{Short}) = "short"
_ccxtisshort(v::Py) = pyeq(Bool, live_side(v), @pyconst("short"))
_ccxtislong(v::Py) = pyeq(Bool, live_side(v), @pyconst("long"))
_ccxtposside(v::Py) =
    if _ccxtislong(v)
        Long()
    elseif _ccxtisshort(v)
        Short()
    else
        _ccxtpnlside(v)
    end
_ccxtposprice(ai, update) =
    let lp = get_float(update, Pos.lastPrice)
        if lp <= zero(DFT)
            lp = get_float(update, Pos.markPrice)
            if lp <= zero(DFT)
                lastprice(ai)
            else
                lp
            end
        else
            lp
        end
    end

function _ccxtpnlside(update)
    upnl = get_float(update, Pos.unrealizedPnl)
    liqprice = get_float(update, Pos.liquidationPrice)
    eprice = get_float(update, Pos.entryPrice)
    ifelse(upnl >= ZERO && liqprice < eprice, Long(), Short())
end

function get_side(update, p::Option{ByPos}=nothing)
    ccxt_side = get_py(update, Pos.side)
    if pyisnone(ccxt_side)
        if isnothing(p)
            @warn "Position side not provided, inferring from position state"
            _ccxtpnlside(update)
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
                _ccxtpnlside(update)
            end
        end
    end
end

function _ccxt_isposclosed(pos::Py) end
