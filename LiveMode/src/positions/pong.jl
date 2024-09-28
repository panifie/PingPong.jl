using PaperMode.SimMode: _lev_value, leverage!, leverage, position!, singlewaycheck
using .st: IsolatedStrategy
using .Executors: hasorders, update_leverage!
using .st: exchange
using .Executors.Instances: raw
using .OrderTypes: isimmediate
using Watchers: fetch!
import .Executors: pong!

@doc """ Updates leverage or places an order in a live trading strategy.

$(TYPEDSIGNATURES)

This function either updates the leverage of a position or places an order in a live trading strategy.
It first checks if the position is open or has pending orders.
If not, it updates the leverage on the exchange and then synchronizes the position.
If an order is to be placed, it checks for any open positions on the opposite side and places the order if none exist.
The function returns the trade or leverage update status.

"""
function Executors.pong!(
    s::MarginStrategy{Live},
    ai::MarginInstance,
    lev,
    ::UpdateLeverage;
    pos::PositionSide,
    synced=false,
    atol=1e-1,
    force=false,
)::Bool
    @lock ai if isopen(ai, pos) || hasorders(s, ai, pos)
        @warn "pong leverage: can't update leverage when position is open or has pending orders" ai = raw(
            ai
        ) s = nameof(s) n_orders = orderscount(s, ai) isopen(ai, pos)
        false
    else
        new_lev = _lev_value(lev)
        since = now()
        this_pos = position(ai, pos)
        prev_lev = leverage(this_pos)
        issameval = isapprox(prev_lev, new_lev; atol)
        # First update on exchange
        if (force || !issameval) &&
            leverage!(exchange(ai), new_lev, raw(ai); timeout=throttle(s))
            leverage!(this_pos, new_lev)
            event!(ai, LeverageUpdated(:leverage_updated, s, this_pos; from_value=prev_lev))
            if synced
                # wait for lev update from watcher
                live_position(s, ai, pos; since, synced=true, force)
                isapprox(leverage(ai, pos), new_lev; atol)
            else
                true
            end
        else
            issameval
        end
    end
end

@doc """ Checks for open positions on the opposite side in an isolated strategy.

$(TYPEDSIGNATURES)

This macro checks if there are any open positions on the opposite side in an isolated trading strategy.
If an open position is found, it issues a warning and returns `nothing`.
The check is performed for the current trade type `t` and the associated asset instance `ai`.

"""
macro isolated_position_check()
    ex = quote
        p = positionside(t)
        if !singlewaycheck(s, ai, t)
            @debug "pong: double direction order in non hedged mode" ai position(ai) order_type =
                t
            return nothing
        end
        side_dict = get_positions(s, opposite(p))
        tup = get(side_dict, raw(ai), nothing)
        if !isnothing(tup) &&
            tup.date >= timestamp(ai, opposite(p)) &&
            !tup.closed[] &&
            _ccxt_isposopen(tup.resp, exchangeid(ai))
            @warn "pong: double direction order in non hedged mode (from resp)" position(ai) order_type = t
            @debug "pong: isolated check" _module = LogPos resp = tup.resp
            return nothing
        end
    end
    esc(ex)
end

_warnpos(p) = @warn "$p Orders are not allowed, other pos ($(opposite(p))) is still open."

@doc """ Executes a limit order in a live trading strategy.

$(TYPEDSIGNATURES)

This function executes a limit order in a live trading strategy, given a strategy `s`, an asset instance `ai`, and a trade type `t`.
It checks for open positions on the opposite side and places the order if none exist.
The function returns the trade or leverage update status.

"""
function Executors.pong!(
    s::IsolatedStrategy{Live},
    ai::MarginInstance,
    t::Type{<:AnyLimitOrder};
    amount,
    price=lastprice(ai),
    waitfor=Second(5),
    skipchecks=false,
    synced=true,
    kwargs...,
)
    @lock ai begin
        skipchecks || @isolated_position_check
        @timeout_start
        order_kwargs = withoutkws(:fees; kwargs)
        trade = _live_limit_order(
            s, ai, t; skipchecks, amount, price, waitfor, synced, kwargs=order_kwargs
        )
        if synced && trade isa Trade
            @debug "pong margin limit order: syncing" ai t
            waitsync(ai; since=trade.date, waitfor=@timeout_now)
            live_sync_position!(
                s, ai, posside(trade); force=true, since=trade.date, waitfor=@timeout_now
            )
        end
        trade
    end
end

@doc """ Executes a market order in a live trading strategy.

$(TYPEDSIGNATURES)

This function executes a market order in a live trading strategy, given a strategy `s`, an asset instance `ai`, and a trade type `t`.
It checks for open positions on the opposite side and places the order if none exist.
The function returns the trade or leverage update status.

"""
function Executors.pong!(
    s::IsolatedStrategy{Live},
    ai::MarginInstance,
    t::Type{<:AnyMarketOrder};
    amount,
    waitfor=Second(5),
    skipchecks=false,
    synced=true,
    kwargs...,
)
    @lock ai begin
        skipchecks || @isolated_position_check
        @timeout_start
        order_kwargs = withoutkws(:fees; kwargs)
        trade = _live_market_order(
            s, ai, t; skipchecks, amount, synced, waitfor, kwargs=order_kwargs
        )
        if synced && trade isa Trade
            waitsync(ai, since=trade.date, waitfor=@timeout_now)
            live_sync_position!(
                s, ai, posside(trade); since=trade.date, waitfor=@timeout_now
            )
        end
        trade
    end
end

_close_order_bypos(::Short) = ShortMarketOrder{Buy}
_close_order_bypos(::Long) = MarketOrder{Sell}

function _posclose_cancel(s, ai, t, pside, waitfor)
    @debug "pong pos close: cancel orders" _module = LogPosClose ai pside
    if hasorders(s, ai, pside)
        if !pong!(s, ai, CancelOrders(); t=BuyOrSell, synced=true, waitfor)
            @warn "pong pos close: failed to cancel orders" ai t
        end
    end
end

function _posclose_maybesync(s, ai, pside, waitfor)
    @debug "pong pos close: sync position" _module = LogPosClose ai pside
    @timeout_start
    update = live_position(s, ai, pside; since=timestamp(ai), waitfor=@timeout_now)
    if isnothing(update)
        @warn "pong pos close: no position update (resetting)" ai pside
        if isopen(ai, pside)
            reset!(ai, pside)
        end
        return (update, true)
    end
    # ensure the last update is read
    if !(update.read[])
        @warn "pong pos close: outdated position state (syncing)." amount = resp_position_contracts(
            update.resp, exchangeid(ai)
        )
        waitsync(ai; since=update.date, waitfor=@timeout_now)
        live_sync_position!(s, ai, pside, update)
    end
    return (update, false)
end

function _posclose_waitsync(s, ai, pside, waitfor)
    @debug "pong pos close: wait for orders" _module = LogPosClose ai pside
    if !waitordclose(s, ai, waitfor)
        @error "pong pos close: orders still pending" ai orderscount(s, ai) cash(ai) committed(
            ai
        )
    end
    # with no orders in flight the local state should be up to date
    return if !isopen(ai, pside)
        @warn "pong pos close: not open locally" ai pside
        true
    else
        false
    end
end

function _posclose_amount(s, ai, pside; kwargs)
    _, this_kwargs = splitkws(:reduce_only, :tag; kwargs)
    amount = cash(ai, pside) |> abs
    @debug "pong pos close: get amount" _module = LogPosClose ai pside amount
    @deassert resp_position_contracts(live_position(s, ai).resp, exchangeid(ai)) == amount
    return amount, this_kwargs
end

function _posclose_trade(s, ai; t, pside, amount, waitfor, this_kwargs)
    @debug "pong pos close: trade" _module = LogPosClose ai pside t
    @timeout_start
    close_trade = pong!(
        s, ai, t; amount, reduce_only=true, tag="position_close", waitfor, this_kwargs...
    )
    if close_trade isa Trade
        (close_trade.date, false)
    elseif isnothing(close_trade)
        # check sync again
        pup = live_position(s, ai, pside; force=true, waitfor=@timeout_now)
        (
            DateTime(0),
            if !isopen(ai, pside)
                @deassert isnothing(pup) || pup.closed[]
                true
            else
                @error "pong pos close: failed to reduce position to zero" ai pside t
                false
            end,
        )
    else
        @warn "pong pos close: closing order delay" orders = collect(
            values(s, ai, orderside(t))
        ) ai t
        (false, timestamp(ai) + Millisecond(1))
    end
end

function _posclose_order(s, ai, pside, since, waitfor)
    @debug "pong pos close: order" _module = LogPosClose ai pside
    @timeout_start
    if !waitposclose(s, ai, pside; waitfor=@timeout_now, force=true)
        @debug "pong pos close: timedout" _module = LogPosClose pside ai = raw(ai)
    end
    waitsync(ai; since, waitfor=@timeout_now)
    live_sync_position!(s, ai, pside; since, overwrite=true, waitfor=@timeout_now)
    if @lock ai isopen(ai, pside)
        pup = live_position(s, ai, pside; since, waitfor=@timeout_now)
        @debug "pong pos close: still open (local) position" _module = LogPosClose since pside date = get(
            pup, :date, nothing
        )
        false
    else
        true
    end
end

function _posclose_lastcheck(s, ai, pside, t, since, waitfor)
    @debug "pong pos close: last check" _module = LogPosClose ai pside
    @timeout_start
    # trade still pending 
    if @lock ai isopen(ai, pside)
        waitsync(ai; since, waitfor=@timeout_now)
        waitsync(s; since, waitfor=@timeout_now())
        return if isopen(ai, pside)
            @error "pong pos close: still open orders (not a market order?)" ai pside t
            false
        else
            true
        end
    else
        true
    end
end

@doc """ Closes a leveraged position in a live trading strategy.

$(TYPEDSIGNATURES)

This function cancels any pending orders and checks the position status.
If the position is open, it places a closing trade and waits for it to be executed.
The function returns `true` if the position is successfully closed, `false` otherwise.

"""
function pong!(
    s::MarginStrategy{Live},
    ai::MarginInstance,
    ::ByPos{P},
    date,
    ::PositionClose;
    t=_close_order_bypos(P()),
    waitfor=Second(15),
    kwargs...,
) where {P<:PositionSide}
    @lock ai begin
        pside = P()
        @timeout_start

        # cancel standing orders
        _posclose_cancel(s, ai, t, pside, @timeout_now)
        # give up if there is no remote position update
        update, isclosed = _posclose_maybesync(s, ai, pside, @timeout_now)
        if isclosed
            return true
        end
        # ensure no more orders are pending and return if pos is closed
        if _posclose_waitsync(s, ai, pside, @timeout_now)
            return true
        end
        # if still open, close manually with a reduce only order
        # get the amount necessary to close the position
        amount, this_kwargs = _posclose_amount(s, ai, pside; kwargs)
        if iszero(amount)
            # Position closed after last check
            return true
        end
        since, isclosed = _posclose_trade(
            s, ai; t, pside, amount, waitfor=@timeout_now(), this_kwargs
        )
        # another check for close in case of failing trade
        if isclosed
            return true
        end
        # trade exec success, wait for completion
        if waitordclose(s, ai, @timeout_now)
            # terminal check after closing trade
            _posclose_order(s, ai, pside, since, @timeout_now)
        else
            # closing trade still pending
            _posclose_lastcheck(s, ai, pside, t, since, @timeout_now)
        end
    end
end
