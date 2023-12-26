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

@doc """ Handles the response from a position fetch request.

$(TYPEDSIGNATURES)

This function takes a response from a position fetch request and an asset instance.
It verifies the response, checks if it matches the requested side (buy/sell), and whether it is for the correct asset.
It returns the relevant position if found, otherwise it returns 'nothing'.

"""
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

@doc """ Fetches and processes the current position for a specific asset and side.

$(TYPEDSIGNATURES)

This function forces a fetch of the current position for a specific asset and side (buy/sell) through the `fetch_positions` function.
It then processes the response using the `_handle_pos_resp` function.
The position is then stored in the position watcher and processed.

"""
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

@doc """ Retrieves the current position for a specific asset and side.

$(TYPEDSIGNATURES)

This function retrieves the current position for a specific asset and side (buy/sell) through the `get_positions` function.
If the function is forced to fetch, or if the data is outdated, it will fetch the position again using the `_force_fetchpos` function.
It waits for the position update to occur and then returns the position update.

"""
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
    w = positions_watcher(s)
    wlocked = islocked(w)
    if (force && !wlocked) || isempty(buffer(w)) &&
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
    if (force && wlocked) ||
       !(isnothing(since) || isnothing(pup))
        if waitforpos(s, ai, side; since, force, waitfor)
        elseif force # try one last time to force fetch
            @debug "live pos: last force fetch"
            _force_fetchpos(s, ai, side; fallback_kwargs)
        end
        pup = get_positions(s, ai, side)
        if !isnothing(since) && (isnothing(pup) || pup.date < since)
            @error "live pos: last force fetch failed" date =
                isnothing(pup) ? nothing : pup.date since force # pup.read[] pup.closed[] f = @caller
            return nothing
        end
    end
    return pup
end

@doc """ Retrieves the current position update for a specific asset.

$(TYPEDSIGNATURES)

This function retrieves the current position update for a specific asset through the `live_position` function and logs the status of the position update.

"""
function _pup(s, ai, args...; kwargs...)
    pup = live_position(s, ai, args...; kwargs...)
    if isnothing(pup)
        @debug "live pup: " f = @caller
    else
        @debug "live pup: " pup.read[] pup.closed[] f = @caller
    end
    pup
end

@doc """ Retrieves the number of contracts for a specific asset in a live strategy.

$(TYPEDSIGNATURES)

This function retrieves the current position update for a specific asset through the `_pup` function.
It then extracts the number of contracts from the position update.
If the asset is short, the function returns the negative of the number of contracts.

"""
function live_contracts(s::LiveStrategy, ai, args...; kwargs...)
    pup = _pup(s, ai, args...; kwargs...)
    if isnothing(pup) || pup.closed[]
        @debug "live contracts: " isnothing(pup) closed = isnothing(pup) ? nothing : pup.closed[]
        ZERO
    else
        amt = resp_position_contracts(pup.resp, exchangeid(ai))
        @debug "live contracts: " amt
        if isshort(ai)
            -amt
        else
            amt
        end
    end
end

@doc """ Retrieves the notional value of a specific asset in a live strategy.

$(TYPEDSIGNATURES)

This function retrieves the current position update for a specific asset through the `_pup` function.
It then extracts the notional value from the position update.

"""
function live_notional(s::LiveStrategy, ai, args...; kwargs...)
    pup = _pup(s, ai, args...; kwargs...)
    if isnothing(pup) || pup.closed[]
        ZERO
    else
        abs(resp_position_notional(pup.resp, exchangeid(ai)))
    end
end

@doc """ Retrieves the maintenance margin requirement (MMR) for a position.

$(TYPEDSIGNATURES)

This function first tries to retrieve the MMR from the live position.
If the retrieved MMR is zero or less, it falls back to the MMR value stored in the position.

"""
_ccxtmmr(lp::Py, pos, eid) =
    let v = resp_position_mmr(lp, eid)
        if v > ZERO
            v
        else
            mmr(pos)
        end
    end

@doc """ Defines a named tuple for positions.  """
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
@doc """ Checks if a position is short.

$(TYPEDSIGNATURES)

This function checks if a position is short by comparing the side of the position with the string "short".
It returns `true` if the position is short, and `false` otherwise.

"""
function _ccxtisshort(v::Py, eid::EIDType)
    pyeq(Bool, resp_position_side(v, eid), @pyconst("short"))
end
@doc """ Checks if a position is long.

$(TYPEDSIGNATURES)

This function checks if a position is long by comparing the side of the position with the string "long".
It returns `true` if the position is long, and `false` otherwise.

"""
_ccxtislong(v::Py, eid::EIDType) = pyeq(Bool, resp_position_side(v, eid), @pyconst("long"))
@doc """ Returns the `PositionSide` of a position from the ccxt position object.

$(TYPEDSIGNATURES)

This function retrieves and returns the side (long/short) of a given position.

"""
_ccxtposside(v::Py, eid::EIDType) =
    if _ccxtislong(v, eid)
        Long()
    elseif _ccxtisshort(v, eid)
        Short()
    else
        _ccxtpnlside(v, eid)
    end

@doc """ Returns the side of a position for a live margin strategy.

$(TYPEDSIGNATURES)

This function retrieves the side (buy/sell) of a given position from a live margin strategy.
If the side is "sell", it returns Short().
If the side is "buy", it returns Long().
If the side is neither "sell" nor "buy", it issues a warning and defaults to the provided default side (Long by default).

"""
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

@doc """ Returns the price of a position.

$(TYPEDSIGNATURES)

This function retrieves the last price of a position.
If the last price is zero or less, it tries to retrieve the mark price.
If the mark price is also zero or less, it defaults to the last price of the asset.
It returns the retrieved price.

"""
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

@doc """ Determines the side of a position based on its unrealized profit and loss (PNL).

$(TYPEDSIGNATURES)

This function determines the side (long/short) of a position based on its unrealized PNL, liquidation price, and entry price.
If the unrealized PNL is greater than or equal to zero and the liquidation price is less than the entry price, it returns Long(). Otherwise, it returns Short().

"""
function _ccxtpnlside(update, eid::EIDType)
    unpnl = resp_position_unpnl(update, eid)
    liqprice = resp_position_liqprice(update, eid)
    eprice = resp_position_entryprice(update, eid)
    ifelse(unpnl >= ZERO && liqprice < eprice, Long(), Short())
end

@doc """ Determines the side of a position based on information from CCXT library.

$(TYPEDSIGNATURES)

This function first checks if the CCXT position side is provided.
If not, it infers the side from the position state or from the provided position object, if available.
If the CCXT side is provided, it checks if it's "short" or "long", and returns Short() or Long() respectively.
If the CCXT side is neither "short" nor "long", it infers the side from the position state and returns it.

"""
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

@doc """ Checks if a position is open based on information from CCXT library.

$(TYPEDSIGNATURES)

This function checks if a position is open by checking if the number of contracts is greater than zero.
It also checks if the initial margin, notional, and liquidation price are non-zero.
If the number of contracts is greater than zero, but any of the other three values are zero, it issues a warning about the position state being dirty.
The function returns `true` if the number of contracts is greater than zero, indicating that the position is open, and `false` otherwise.

"""
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

@doc """ Checks if a position is closed based on information from CCXT library.

$(TYPEDSIGNATURES)

This function checks if a position is closed by checking if the number of contracts is zero.
It also checks if the initial margin, notional, unrealized PNL, and liquidation price are non-zero.
If the number of contracts is zero, but any of the other four values are non-zero, it issues a warning about the position state being dirty.
The function returns `true` if the number of contracts is zero, indicating that the position is closed, and `false` otherwise.

"""
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

@doc """ Waits for a position to reach a certain state.

$(TYPEDSIGNATURES)

This function waits for a position to reach a certain state based on several parameters.
- `bp`: The position side (default is the side of the asset).
- `since`: The time from which to start waiting (optional).
- `waitfor`: The time to wait for the position to reach the desired state (default is 5 seconds).
- `force`: A boolean that determines whether to forcefully wait until the position is found (default is true).
- `fallback_kwargs`: Additional keyword arguments (optional).

The function fetches the position and checks if it has reached the desired state.
If it has not, it waits for a specified period and then checks again.
This process is repeated until the position reaches the desired state, or the function times out.
If the function times out, it returns `false`.
If the position reaches the desired state within the time limit, the function returns `true`.

"""
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

@doc """ Waits for a local position to reach a certain state.

$(TYPEDSIGNATURES)

This function waits for a local position to reach a certain state based on several parameters.
The function fetches the position's timestamp and checks if it has changed.
If it has not, it waits for a specified period and then checks again.
This process is repeated until the timestamp changes, or the function times out.

"""
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

@doc """ Waits for a position to close.

$(TYPEDSIGNATURES)

This function waits for a position to close based on several parameters.
- `bp`: The position side (default is the side of the asset).
- `waitfor`: The time to wait for the position to close (default is 5 seconds).
- `sync`: A boolean that determines whether to sync live positions (default is true).

The function fetches the position status and checks if it's closed. If not, it waits for a specified period and checks again. This process is repeated until the position is closed, or the function times out.

If the function times out, it returns `false`. If the position closes within the time limit, the function returns `true`.

"""
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
