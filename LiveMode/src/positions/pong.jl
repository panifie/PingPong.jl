using PaperMode.SimMode: _lev_value, leverage!, leverage, position!
using .st: IsolatedStrategy
using .Executors: hasorders, update_leverage!
using .st: exchange
using .Executors.Instances: raw
using .OrderTypes: isimmediate
using Watchers: fetch!
import .Executors: pong!, aftertrade!

function Executors.pong!(
    s::MarginStrategy{Live}, ai::MarginInstance, lev, ::UpdateLeverage; pos::PositionSide
)
    if isopen(ai, pos) || hasorders(s, ai, pos)
        @warn "pong leverage: can't update leverage when position is open or has pending orders" ai = raw(
            ai
        ) s = nameof(s)
        false
    else
        val = _lev_value(lev)
        since = now()
        # First update on exchange
        if leverage!(exchange(ai), val, raw(ai))
            # then sync position
            live_sync_position!(s, ai, pos; force=false, since)
        end
        @deassert isapprox(leverage(ai, pos), val, rtol=0.01) (leverage(ai, pos), lev)
        true
    end
end

macro isolated_position_check()
    ex = quote
        p = positionside(t)
        if isopen(ai, opposite(p))
            _warnpos(p)
            return nothing
        end
        side_dict = get_positions(s, opposite(p))
        tup = get(side_dict, raw(ai), nothing)
        if !isnothing(tup) && !tup.closed[] && _ccxt_isposopen(tup.resp, exchangeid(ai))
            _warnpos(p)
            return nothing
        end
    end
    esc(ex)
end

_warnpos(p) = @warn "$p Orders are not allowed, other pos ($(opposite(p))) is still open."

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
    trade = _live_limit_order(s, ai, t; amount, price, waitfor, synced, kwargs)
    if synced && trade isa Trade
        live_sync_position!(
            s, ai, posside(trade); force=true, since=trade.date, waitfor=@timeout_now
        )
    end
    trade
end

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
    trade = _live_market_order(s, ai, t; amount, synced, waitfor, kwargs)
    if synced && trade isa Trade
        live_sync_position!(
            s, ai, posside(trade); force=true, since=trade.date, waitfor=@timeout_now
        )
    end
    trade
end

_close_order_bypos(::Short) = ShortMarketOrder{Buy}
_close_order_bypos(::Long) = MarketOrder{Sell}

@doc "Closes a leveraged position (Live)."
function pong!(
    s::MarginStrategy{Live},
    ai,
    ::ByPos{P},
    date,
    ::PositionClose;
    t=_close_order_bypos(P()),
    waitfor=Second(10),
    kwargs...,
) where {P<:PositionSide}
    pos = P()
    @timeout_start
    pong!(s, ai, CancelOrders(); t=Both, synced=false, waitfor=@timeout_now)
    update = live_position(s, ai)
    if isnothing(update)
        @warn "pong pos close: no position update (resetting)" ai = raw(ai) side = P
        isopen(ai, P()) && reset!(ai, P())
        return true
    end
    if !(update.read[])
        @warn "pong pos close: outdated position state (syncing)." amount = resp_position_contracts(
            update.resp, exchangeid(ai)
        )
        live_sync_position!(s, ai, P(), update)
    end
    isopen(ai, pos) || begin
        @warn "pong pos close: not open locally" ai = raw(ai) side = P
        return true
    end
    _, this_kwargs = splitkws(:reduce_only; kwargs)
    waitfor_closed(s, ai, @timeout_now) ||
        @error "pong pos close: orders still pending" orderscount(s, ai) cash(ai) committed(
            ai
        )
    amount = ai |> cash |> abs
    @deassert resp_position_contracts(live_position(s, ai).resp, exchangeid(ai)) == amount
    close_trade = pong!(
        s, ai, t; amount, reduce_only=true, waitfor=@timeout_now, this_kwargs...
    )
    since = if close_trade isa Trade
        close_trade.date
    else
        @warn "pong pos close: missing trade" values(s, ai, orderside(t)) ai = raw(ai)
        now()
    end
    if waitfor_closed(s, ai, @timeout_now)
        if waitposclose(s, ai, P; waitfor=@timeout_now)
        else
            @debug "pong pos close: timedout" pos = P ai = raw(ai)
        end
        live_sync_position!(
            s, ai, P(); since, force=true, strict=true, waitfor=@timeout_now
        )
        if @lock ai isopen(ai, pos)
            @debug "pong pos close:" timestamp(ai, pos) >= since timestamp(ai, pos) ==
                DateTime(0)
            pup = live_position(s, ai, pos; since, waitfor=@timeout_now)
            @debug "pong pos close: still open (local) position" since position(ai, pos) data =
                try
                    resp = fetch_positions(s, ai)[0]
                    this_pup = live_position(
                        s, ai, P(); since, force=true, waitfor=@timeout_now
                    )
                    eid = exchangeid(ai)
                    (;
                        prev_pup=if isnothing(pup)
                            nothing
                        else
                            (; pup.date, pup.closed, pup.read)
                        end,
                        open_orders=fetch_open_orders(s, ai),
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
