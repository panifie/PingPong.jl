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
    if isopen(ai, pos) || hasorders(s, ai, pos)
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
                waitforpos(s, ai, pos; since)
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
    skipchecks || @isolated_position_check
    @timeout_start
    order_kwargs = withoutkws(:fees; kwargs)
    trade = _live_limit_order(
        s, ai, t; skipchecks, amount, price, waitfor, synced, kwargs=order_kwargs
    )
    if synced && trade isa Trade
        live_sync_position!(
            s, ai, posside(trade); force=true, since=trade.date, waitfor=@timeout_now
        )
    end
    trade
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
    skipchecks || @isolated_position_check
    @timeout_start
    order_kwargs = withoutkws(:fees; kwargs)
    trade = _live_market_order(
        s, ai, t; skipchecks, amount, synced, waitfor, kwargs=order_kwargs
    )
    if synced && trade isa Trade
        live_sync_position!(s, ai, posside(trade); since=trade.date, waitfor=@timeout_now)
    end
    trade
end

_close_order_bypos(::Short) = ShortMarketOrder{Buy}
_close_order_bypos(::Long) = MarketOrder{Sell}

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
    pos = P()
    @timeout_start
    if hasorders(s, ai, P)
        if !pong!(s, ai, CancelOrders(); t=BuyOrSell, synced=true, waitfor=@timeout_now)
            @warn "pong pos close: failed to cancel orders" ai t
        end
    end
    update = live_position(s, ai, pos)
    if isnothing(update)
        @warn "pong pos close: no position update (resetting)" ai side = P
        isopen(ai, P()) && reset!(ai, pos)
        return true
    end
    if !(update.read[])
        @warn "pong pos close: outdated position state (syncing)." amount = resp_position_contracts(
            update.resp, exchangeid(ai)
        )
        live_sync_position!(s, ai, pos, update)
    end
    if !isopen(ai, pos)
        @warn "pong pos close: not open locally" ai side = P
        return true
    end
    if !waitfor_closed(s, ai, @timeout_now)
        @error "pong pos close: orders still pending" ai orderscount(s, ai) cash(ai) committed(
            ai
        )
    end
    _, this_kwargs = splitkws(:reduce_only, :tag; kwargs)
    amount = cash(ai, pos) |> abs
    if iszero(amount)
        # Position closed after last check
        return true
    end
    @deassert resp_position_contracts(live_position(s, ai).resp, exchangeid(ai)) == amount
    close_trade = pong!(
        s,
        ai,
        t;
        amount,
        reduce_only=true,
        tag="position_close",
        waitfor=@timeout_now,
        this_kwargs...,
    )
    since = if close_trade isa Trade
        close_trade.date
    elseif isnothing(close_trade)
        # sync (of a previous closing order) might have happened during previous order attempt
        if isopen(ai, pos)
            @error "pong pos close: failed to reduce position to zero" ai P t
            return false
        else
            return true
        end
    else
        @warn "pong pos close: closing order delay" orders = collect(
            values(s, ai, orderside(t))
        ) ai t
        timestamp(ai) + Millisecond(1)
    end
    if waitfor_closed(s, ai, @timeout_now)
        if waitposclose(s, ai, P; waitfor=@timeout_now)
        else
            @debug "pong pos close: timedout" _module = LogPosClose pos = P ai = raw(ai)
        end
        live_sync_position!(s, ai, P(); since, overwrite=true, waitfor=@timeout_now)
        if @lock ai isopen(ai, pos)
            @debug "pong pos close:" _module = LogPosClose timestamp(ai, pos) >= since timestamp(
                ai, pos
            ) == DateTime(
                0
            )
            pup = live_position(s, ai, pos; since, waitfor=@timeout_now)
            @debug "pong pos close: still open (local) position" _module = LogPosClose since position(
                ai, pos
            ) data = try
                resp = first(fetch_positions(s, ai))
                this_pup = live_position(s, ai, P(); since, waitfor=@timeout_now)
                eid = exchangeid(ai)
                (;
                    prev_pup=if isnothing(pup)
                        nothing
                    else
                        (; pup.date, pup.closed, pup.read)
                    end,
                    live_pos=(;
                        timestamp=resp_position_timestamp(this_pup.resp, eid),
                        amount=resp_position_contracts(this_pup.resp, eid),
                    ),
                    fetch_pos=(;
                        timestamp=resp_position_timestamp(resp, eid),
                        amount=resp_position_contracts(resp, eid),
                    ),
                )
            catch
            end
            false
        else
            true
        end
    else
        if @lock ai isopen(ai, P())
            @warn "pong pos close: still open orders" P cash(ai) ai = raw(ai)
            false
        else
            true
        end
    end
end
