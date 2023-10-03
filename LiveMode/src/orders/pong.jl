using .Executors: AnyLimitOrder

@doc "Creates a live limit order."
function pong!(
    s::NoMarginStrategy{Live},
    ai,
    t::Type{<:AnyLimitOrder};
    amount,
    price=lastprice(s, ai, t),
    waitfor=Second(1),
    synced=true,
    kwargs...,
)::Union{<:Trade,Nothing,Missing}
    @timeout_start
    trade = _live_limit_order(s, ai, t; amount, price, waitfor, synced, kwargs)
    if synced && trade isa Trade
        live_sync_cash!(s, ai; since=trade.date, waitfor=@timeout_now)
    end
    trade
end

@doc "Creates a live market order."
function pong!(
    s::NoMarginStrategy{Live},
    ai,
    t::Type{<:AnyMarketOrder};
    amount,
    waitfor=Second(5),
    synced=true,
    kwargs...,
)
    @timeout_start
    trade = _live_market_order(s, ai, t; amount, synced, waitfor, kwargs)
    if synced && trade isa Trade
        live_sync_cash!(s, ai; since=trade.date, waitfor=@timeout_now)
    end
    trade
end

@doc "Cancel orders for a particular asset instance."
function pong!(
    s::Strategy{Live},
    ai::AssetInstance,
    ::CancelOrders;
    t::Type{<:OrderSide}=Both,
    waitfor=Second(10),
    confirm=false,
    synced=true,
)
    @timeout_start
    if live_cancel(s, ai; side=t, confirm, all=true)::Bool
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
