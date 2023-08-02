using .Instances: MarginInstance, raw, cash, cash!
using .Python: PyException, pyisinstance, pybuiltins, @pystr, pytryfloat, pytruth, pyconvert
using .Python.PythonCall: pyisTrue, Py, pyisnone
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
    _status!,
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

function live_position(ai::MarginInstance; keep_info=false)
    exc = exchange(ai)
    resp = if exc.has[:fetchPosition]
        pyfetch(exc.fetchPosition, raw(ai))
    else
        pyfetch(exc.fetchPositions, (raw(ai),))
    end
    ccxt_pos = if resp isa PyException
        return nothing
    elseif pyisinstance(resp, pybuiltins.list)
        isempty(resp) && return nothing
        first(resp)
    end
    if pyisinstance(ccxt_pos, pybuiltins.dict) &&
        pyisTrue(ccxt_pos.get("symbol") == @pystr(raw(ai)))
        keep_info || ccxt_pos.pop("info")
        ccxt_pos
    else
        return nothing
    end
end

get_float(v::Py, k) = v.get(k) |> pytofloat
get_bool(v::Py, k) = v.get(k) |> pytruth
get_time(v::Py, k) =
    let d = v.get(k)
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
    PosFields = (;
        liquidationPrice="liquidationPrice",
        initialMargin="initialMargin",
        maintenanceMargin="maintenanceMargin",
        collateral="collateral",
        entryPrice="entryPrice",
        timestamp="timestamp",
        lastUpdateTimestamp="lastUpdateTimestamp",
        additionalMargin="additionalMargin",
        notional="notional",
        contracts="contracts",
        symbol="symbol",
        unrealizedPnl="unrealizedPnl",
        leveraged="leveraged",
        id="id",
        contractSize="contractSize",
        markPrice="markPrice",
        lastPrice="lastPrice",
        marginMode="marginMode",
        marginRatio="marginRatio",
        datetime="datetime",
        side="side",
        hedged="hedged",
        percentage="percentage",
    )

_ccxtposside(::ByPos{Long}) = "long"
_ccxtposside(::ByPos{Short}) = "short"
_ccxtposprice(ai, update) =
    let lp = update.get(Pos.lastPrice) |> pytofloat
        if lp <= zero(DFT)
            lp = update.get(Pos.markPrice) |> pytofloat
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
    upnl = update.get(Pos.unrealizedPnl) |> pytofloat
    liqprice = update.get(Pos.liquidationPrice) |> pytofloat
    eprice = update.get(Pos.entryPrice) |> pytofloat
    ifelse(upnl >= ZERO && liqprice < eprice, Long(), Short())
end

function sync!(
    s::MarginStrategy,
    ai::MarginInstance,
    p::Option{ByPos},
    update::Py;
    amount=live_amount(update),
    ep=live_entryprice(update),
    commits=true,
)
    # If position side doesn't match we should abort sync
    ccxt_side = update.get(Pos.side)
    pside = if pyisnone(ccxt_side)
        if isnothing(p)
            @warn "Position side not provided, inferring from position state"
            _ccxtpnlside(update)
        else
            posside(p)()
        end
    else
        let side_str = ccxt_side.lower()
            if pyisTrue(side_str == @pystr("short"))
                Short()
            elseif pyisTrue(side_str == @pystr("long"))
                Long()
            else
                @warn "Position side flag not valid, inferring from position state"
                _ccxtpnlside(update)
            end
        end
    end
    pos = position(ai, pside)

    # check hedged mode
    get_bool(update, Pos.hedged) == pos.hedged ||
        @warn "Position hedged mode mismatch (local: $(pos.hedged))"
    @assert pos.hedged || !isopen(opposite(ai, pside)) "Double position open in NON hedged mode."
    this_time = get_time(update, "timestamp")
    pos.timestamp[] == this_time && return pos

    # Margin/hedged mode are immutable so just check for mismatch
    let mm = update.get(Pos.marginMode)
        pyisnone(mm) ||
            mm == @pystr(marginmode(pos)) ||
            @warn "Position margin mode mismatch (local: $(marginmode(pos)))"
    end

    # update cash, (always positive for longs, or always negative for shorts)
    cash!(pos, islong(pos) ? (amount |> abs) : (amount |> abs |> negate))
    # If the updated amount is "dust" the position should be considered closed, and to be reset
    pos_price = _ccxtposprice(ai, update)
    if isdust(ai, pos_price, pside)
        reset!(pos)
        return pos
    end
    pos.status[] = PositionOpen()
    dowarn(what, val) = @warn "Unable to sync $what from $(nameof(exchange(ai))), got $val"
    # price is always positive
    ep = if ep > zero(DFT)
        entryprice!(pos, ep)
        ep
    else
        entryprice!(pos, pos_price)
        dowarn("entry price", ep)
        pos_price
    end
    commits && let comm = committed(s, ai, pside)
        isapprox(committed(pos), comm) || commit!(pos, comm)
    end

    lev = get_float(update, "leverage")
    if lev > zero(DFT)
        leverage!(pos, lev)
    else
        dowarn("leverage", lev)
        lev = one(DFT)
    end
    ntl = let v = get_float(update, Pos.notional)
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
    lqp = get_float(update, Pos.liquidationPrice)
    liqprice_set = lqp > zero(DFT) && (liqprice!(pos, lqp); true)

    mrg = get_float(update, Pos.initialMargin)
    coll = get_float(update, Pos.collateral)
    adt = max(zero(DFT), coll - mrg)
    mrg_set = mrg > zero(DFT) && begin
        initial!(pos, mrg)
        additional!(pos, adt)
        true
    end
    mm = get_float(update, Pos.maintenanceMargin)
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
            liqprice(pside, ep, lev, live_mmr(update, pos); additional=adt, notional=ntl),
        )
    end
    mrg_set || _margin!()
    mm_set || update_maintenance!(pos; mmr=live_mmr(update, pos))
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
    timestamp!(pos, get_time(update, "timestamp"))
    return pos
end

function sync!(s::MarginStrategy, ai::MarginInstance, p=position(ai))
    update = live_position(ai)
    sync!(s, ai, p, update)
end

function live_pnl!(ai::MarginInstance, p::ByPos; keep_info=false)
    lp = live_position(ai::MarginInstance)
    pos = position(ai, p)
    pnl = lp.get("unrealizedPnl") |> pytofloat
    if iszero(pnl)
        amount = lp.get("contracts") |> pytofloat
        function dowarn(a, b)
            @warn "Position amount for $(raw(ai)) unsynced from exchange $(nameof(exchange(ai))) ($a != $b), resyncing..."
        end
        resync = false
        if amount > zero(DFT)
            if !isapprox(amount, abs(cash(pos)))
                dowarn(amount, abs(cash(pos).value))
            end
            ep = lp.get("entryprice") |> pytofloat
            if !isapprox(ep, entryprice(pos))
                dowarn(amount, entryprice(pos))
            end
            # calc pnl manually
            v = pnl(pos)
            if resync
            end
        else
            pnl
        end
    else
        pnl
    end
end
