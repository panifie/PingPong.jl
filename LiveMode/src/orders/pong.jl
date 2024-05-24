using .Executors: AnyLimitOrder

@doc """ Places a limit order and synchronizes the cash balance.

$(TYPEDSIGNATURES)

This function initiates a limit order through the `_live_limit_order` function.
Once the order is placed, it synchronizes the cash balance in the live strategy to reflect the transaction.
It returns the trade information once the transaction is complete.

"""
function pong!(
    s::NoMarginStrategy{Live},
    ai,
    t::Type{<:AnyLimitOrder};
    amount,
    price=lastprice(s, ai, t),
    waitfor=Second(5),
    synced=true,
    skipchecks=false,
    kwargs...,
)::Union{<:Trade,Nothing,Missing}
    @timeout_start
    w = balances_watcher(s)
    # NOTE: avoid balances updates when executing orders
    trade = @lock w._exec.buffer_lock _live_limit_order(s, ai, t; skipchecks, amount, price, waitfor, synced, kwargs)
    if synced && trade isa Trade
        live_sync_cash!(s, ai; since=trade.date, waitfor=@timeout_now)
    end
    trade
end

@doc """ Places a market order and synchronizes the cash balance.

$(TYPEDSIGNATURES)

This function initiates a market order through the `_live_market_order` function.
Once the order is placed, it synchronizes the cash balance in the live strategy to reflect the transaction.
It returns the trade information once the transaction is complete.

"""
function pong!(
    s::NoMarginStrategy{Live},
    ai,
    t::Type{<:AnyMarketOrder};
    amount,
    waitfor=Second(5),
    synced=true,
    skipchecks=false,
    kwargs...,
)
    @timeout_start
    w = balances_watcher(s)
    # NOTE: avoid balances updates when executing orders
    trade = @lock w._exec.buffer_lock _live_market_order(s, ai, t; skipchecks, amount, synced, waitfor, kwargs)
    if synced && trade isa Trade
        waitfororder(s, ai, trade.order; waitfor=@timeout_now)
        live_sync_cash!(s, ai; since=trade.date, waitfor=@timeout_now)
    end
    trade
end

@doc """ Cancels all live orders of a certain type and synchronizes the cash balance.

$(TYPEDSIGNATURES)

This function cancels all live orders of a certain side (buy/sell) through the `live_cancel` function.
Once the orders are canceled, it waits for confirmation of the cancelation and then synchronizes the cash balance in the live strategy to reflect the cancelations.
It returns a boolean indicating whether the cancellation was successful.

"""
function pong!(
    s::Strategy{Live},
    ai::AssetInstance,
    ::CancelOrders;
    t::Type{<:OrderSide}=BuyOrSell,
    waitfor=Second(10),
    confirm=false,
    synced=true,
    ids=(),
)
    @timeout_start
    if !hasorders(s, ai, t) && !confirm
        @debug "pong cancel orders: no local open orders" _module = LogCancelOrder
        return true
    end
    watch_orders!(s, ai)
    if live_cancel(s, ai; ids, side=t, confirm)::Bool
        success = waitfor_closed(s, ai, @timeout_now; t)
        if success && synced
            @debug "pong cancel orders: syncing cash" side = orderside(t)
            live_sync_cash!(s, ai; waitfor=@timeout_now)
        end
        @debug "pong cancel orders: " success side = orderside(t)
        success
    else
        @debug "pong cancel orders: failed" side = orderside(t)
        false
    end
end
