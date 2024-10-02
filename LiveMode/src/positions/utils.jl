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
using .Python: pyisTrue, pyisnone, Py
using .Python.PythonCall: pyeq
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
import .Instances: posside

_ispossym(py, sym, eid::EIDType) = pyeq(Bool, resp_position_symbol(py, eid), @pystr(sym))
posside(s::Strategy, ai::MarginInstance) = @something posside(ai) get_position_side(s, ai)

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
        @debug "force fetch pos: error $sym($side)" _module = LogPosFetch resp
        return nothing
    elseif islist(resp)
        return resp
    elseif isdict(resp) && _ccxtposside(resp, eid) == side && _ispossym(resp, sym, eid)
        return pylist((resp,))
    else
        @debug "force fetch pos: unhandled response $sym($side)" _module = LogPosFetch resp
        return nothing
    end
end

@doc """ Fetches and processes the current position for a specific asset and side.

$(TYPEDSIGNATURES)

This function forces a fetch of the current position for a specific asset and side (buy/sell) through the `fetch_positions` function.
It then processes the response using the `_handle_pos_resp` function.
The position is then stored in the position watcher and processed.

"""
function _force_fetchpos(s, ai, side; waitfor=s[:positions_base_timeout][], fallback_kwargs)
    @timeout_start
    let cache = _positions_resp_cache(s.attrs)
        @lock cache.lock empty!(cache.data)
    end
    w = positions_watcher(s)
    last_time = lastdate(w)
    prev_pup = get_positions(s, ai, side)

    function skip_if_updated(waitfor=@timeout_now)
        @debug "force fetch pos: checking if updated" _module = LogPosForceFetch ai islocked(
            w
        )
        if _isupdated(w, prev_pup, last_time; this_v_func=() -> get_positions(s, ai, side))
            @debug "force fetch pos: updated" _module = LogPosForceFetch ai islocked(w)
            waitsync(ai; waitfor)
            true
        else
            false
        end
    end

    @debug "force fetch pos: waiting" _module = LogPosForceFetch ai islocked(w) f = @caller(10)
    waitsync(ai; waitfor=@timeout_now)
    skip_if_updated() && return nothing

    @debug "force fetch pos: locking" _module = LogPosForceFetch ai islocked(w)
    resp = @lock w begin
        skip_if_updated() && return nothing
        timeout = @timeout_now()
        if timeout > Second(0)
            @debug "force fetch pos: fetching" _module = LogPosForceFetch ai timeout
            # NOTE: don't pass neighter the instance nor the side, always fetch all positions
            # otherwise it breaks watcher updates processing
            let resp = fetch_positions(s; timeout, fallback_kwargs...)
                _handle_pos_resp(resp, ai, side)
            end
        end
    end
    if !isnothing(resp)
        @debug "force fetch pos:" _module = LogPosForceFetch ai amount = try
            if isempty(resp)
                nothing
            else
                resp_position_contracts(first(resp), exchangeid(ai))
            end
        catch
            @debug_backtrace LogPosForceFetch
        end exchangeid(ai)
        push!(w.buf_process, (resp, true))
        notify(w.buf_notify)
        @debug "force fetch pos: processing" _module = LogPosForceFetch ai
        skip_if_updated() && return nothing
        waitsync(ai; waitfor=@timeout_now)
    end
    @debug "force fetch pos: done" _module = LogPosForceFetch ai lastdate(w)
end

function _isstale(ai, pup, side, since)
    if isnothing(pup)
        true
    elseif isnothing(since)
        false
    else
        time = @something(pytodate(pup.resp, exchangeid(ai)), timestamp(ai, side))
        time < since
    end
end

@doc """ Retrieves the current position for a specific asset and side.

$(TYPEDSIGNATURES)

This function retrieves the current position for a specific asset and side (buy/sell) through the `get_positions` function.
If the function is forced to fetch, or if the data is outdated, it will fetch the position again using the `_force_fetchpos` function.
It waits for the position update to occur and then returns the position update.
Prefer to use `since` argument, only use `force` to ensure that the latest update is fetched.

"""
function live_position(
    s::LiveStrategy,
    ai,
    side=get_position_side(s, ai);
    fallback_kwargs=(),
    since=nothing,
    force=false,
    synced=false,
    waitfor=Second(10),
    drift=Millisecond(5),
)
    @timeout_start
    getpos()::Option{PositionTuple} = get_positions(s, ai, side)
    waitw(waitfor=@timeout_now) = waitsync(ai; since, waitfor)
    forcepos() = _force_fetchpos(s, ai, side; waitfor, fallback_kwargs)

    return if !isnothing(since)
        function waitsincefunc(pup=get_positions(s, ai, side))
            !isnothing(pup) && pup.date + drift >= since
        end
        waitforcond(waitsincefunc, @timeout_now())
        if @istimeout()
            @debug "live pos: since timeout" _module = LogPosFetch ai side since
            if !waitsincefunc()
                if force
                    forcepos()
                elseif synced
                    waitw()
                end
            end
            pup = getpos()
            if waitsincefunc(pup)
                pup
            end
        else
            getpos()
        end
    elseif force
        @debug "live pos: force fetching position" _module = LogPosFetch ai side
        forcepos()
        waitw()
        getpos()
    elseif synced
        waitw()
        getpos()
    else
        getpos()
    end
end

@doc """ Retrieves the current position update for a specific asset.

$(TYPEDSIGNATURES)

This function retrieves the current position update for a specific asset through the `live_position` function and logs the status of the position update.

"""
function _pup(s, ai, args...; kwargs...)
    pup = live_position(s, ai, args...; kwargs...)
    if isnothing(pup)
        @debug "live pup: " _module = LogPosFetch f = @caller
    else
        @debug "live pup: " _module = LogPosFetch pup.read[] pup.closed[] f = @caller
    end
    pup
end

@doc """ Retrieves the number of contracts for a specific asset in a live strategy.

$(TYPEDSIGNATURES)

This function retrieves the current position update for a specific asset through the `_pup` function.
It then extracts the number of contracts from the position update.
If the asset is short, the function returns the negative of the number of contracts.

"""
function live_contracts(
    s::LiveStrategy,
    ai,
    pside=nothing,
    args...;
    synced=false,
    local_fallback=true,
    waitfor=Second(5),
    kwargs...,
)
    @timeout_start
    watch_positions!(s)
    waitsync(ai; waitfor=@timeout_now)
    pup = _pup(s, ai, pside, args...; synced, waitfor, kwargs...)
    function dosync()
        if !pup.read[]
            waitsync(ai; since=timestamp(ai, pside), waitfor=@timeout_now)
            live_sync_position!(s, ai, pside, pup; waitfor=@timeout_now)
            waitsync(ai, waitfor=@timeout_now)
        end
    end
    if isnothing(pside)
        pside = posside(ai)
        if isnothing(pside)
            @debug "live contracts: no side" _module = LogPosFetch
            return 0.0
        end
    end
    if isnothing(pup)
        @debug "live contracts: no position" _module = LogPosFetch isnothing(pup) closed =
            isnothing(pup) ? nothing : pup.closed[]
        if local_fallback
            @debug "live contracts: fallback" _module = LogPosFetch ai pside
            cash(ai, pside).value
        else
            0.0
        end
    else
        dosync()
        cash(ai, pside).value
    end
end

@doc """ Retrieves the notional value of a specific asset in a live strategy.

$(TYPEDSIGNATURES)

This function retrieves the current position update for a specific asset through the `_pup` function.
It then extracts the notional value from the position update.

"""
function live_notional(s::LiveStrategy, ai, args...; kwargs...)
    @debug "live: notional" _module = LogPosSync ai
    pup = _pup(s, ai, args...; kwargs...)
    if isnothing(pup) || pup.closed[]
        0.0
    else
        eid = exchangeid(ai)
        ntl = resp_position_notional(pup.resp, eid)
        if iszero(ntl) && timestamp(ai) >= get_time(pup.resp, eid)
            notional(ai, get_position_side(s, ai))
        else
            ntl
        end |> abs
    end
end

@doc """ Retrieves the maintenance margin requirement (MMR) for a position.

$(TYPEDSIGNATURES)

This function first tries to retrieve the MMR from the live position.
If the retrieved MMR is zero or less, it falls back to the MMR value stored in the position.

"""
_ccxtmmr(lp::Py, pos, eid) =
    let v = resp_position_mmr(lp, eid)
        if v > 0.0
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
_ccxtposside(v::Py, eid::EIDType; def=Long()) =
    if _ccxtislong(v, eid)
        Long()
    elseif _ccxtisshort(v, eid)
        Short()
    else
        _ccxtpnlside(v, eid; def)
    end

@doc """ Returns the side of a position for a live margin strategy.

$(TYPEDSIGNATURES)

This function retrieves the side (buy/sell) of a given position from a live margin strategy.
If the side is "sell", it returns Short().
If the side is "buy", it returns Long().
If the side is neither "sell" nor "buy", it issues a warning and defaults to the provided default side (Long by default).

"""
function _ccxtposside(::MarginStrategy{Live}, v::Py, eid::EIDType; def=Long())
    side = resp_order_side(v, eid)
    is_reduce_only = resp_order_reduceonly(v, eid)
    if pyeq(Bool, side, @pyconst("sell"))
        ifelse(is_reduce_only, Long(), Short())
    elseif pyeq(Bool, side, @pyconst("buy"))
        ifelse(is_reduce_only, Short(), Long())
    else
        @warn "Side value not found, defaulting to $def" resp = v
        def
    end
end
_ccxtposside(::NoMarginStrategy{Live}, args...; kwargs...) = Long()
_ccxtposside(v::String) =
    if v == "long"
        Long()
    elseif v == "short"
        Short()
    else
        error("wrong position side value $v")
    end

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
            date = resp_position_timestamp(update, eid)
            lastprice(ai, date)
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
function _ccxtpnlside(update, eid::EIDType; def=Long())
    unpnl = resp_position_unpnl(update, eid)
    liqprice = resp_position_liqprice(update, eid)
    eprice = resp_position_entryprice(update, eid)
    @debug "ccxt pnl side" _module = LogCcxtFuncs unpnl liqprice eprice
    if iszero(eprice) || iszero(liqprice)
        contracts = resp_position_contracts(update, eid)
        if contracts < 0.0
            Short()
        elseif contracts > 0.0
            Long()
        else
            def
        end
    elseif unpnl >= 0.0 && liqprice < eprice
        Long()
    else
        Short()
    end
end

@doc """ Determines the side of a position based on information from CCXT library.

$(TYPEDSIGNATURES)

This function first checks if the CCXT position side is provided.
If not, it infers the side from the position state or from the provided position object, if available.
If the CCXT side is provided, it checks if it's "short" or "long", and returns Short() or Long() respectively.
If the CCXT side is neither "short" nor "long", it infers the side from the position state and returns it.
If the side can't be parsed, a function `default_side_func` can be passed as argument that takes as input the response and returns a `PositionSide`.

"""
function posside_fromccxt(
    update, eid::EIDType, p::Option{ByPos}=nothing; default_side_func=Returns(nothing)
)
    ccxt_side = resp_position_side(update, eid)
    def_side = isnothing(p) ? Long() : posside(p) # NOTE: posside(...) can still be nothing
    if pyisnone(ccxt_side)
        @debug "ccxt posside: side not provided, inferring from position state" _module =
            LogCcxtFuncs @caller
        @something _ccxtpnlside(update, eid, def=def_side) default_side_func(update)
    else
        side_str = ccxt_side.lower()
        if pyeq(Bool, side_str, @pyconst("short"))
            Short()
        elseif pyeq(Bool, side_str, @pyconst("long"))
            Long()
        else
            @debug "ccxt posside: side flag not valid (non open pos?), inferring from position state" _module =
                LogCcxtFuncs side_str resp_position_contracts(update, eid) f = @caller
            def_side = @something default_side_func(update) def_side
            side::PositionSide = _ccxtpnlside(update, eid; def=def_side)
            @debug "ccxt posside: inferred" _module = LogCcxtFuncs def_side side
            side
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
    c = resp_position_contracts(pos, eid) > 0.0
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

function waitposclose(
    s::LiveStrategy,
    ai,
    bp::ByPos=get_position_side(s, ai);
    waitfor=Second(5),
    since=nothing,
    synced=true,
    force=false,
)
    @timeout_start
    isclosed() = !isopen(ai, bp)
    while true
        pup = live_position(s, ai, bp; since, synced, force, waitfor=@timeout_now())
        waitsync(ai; since, waitfor=@timeout_now)
        if !isnothing(pup)
            if isclosed()
                return true
            elseif @istimeout()
                return false
            end
        elseif @istimeout()
            return isclosed()
        end
    end
end
