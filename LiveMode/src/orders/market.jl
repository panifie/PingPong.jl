function _live_market_order(s, ai, t; amount, synced, waitfor, kwargs)
    o = create_live_order(
        s, ai; t, amount, price=lastprice(ai, Val(:history)), exc_kwargs=kwargs
    )
    @deassert o isa AnyMarketOrder{orderside(t)} o
    isnothing(o) && return nothing
    @debug "market order: created" id = o.id hasorders(s, ai, o.id)
    order_trades = trades(o)
    @timeout_start

    if !isempty(order_trades) ||
        (waitfororder(s, ai, o; waitfor=@timeout_now) && !isempty(order_trades))
        last(order_trades)
    else
        if waitfortrade(s, ai, o; waitfor=@timeout_now)
            last(order_trades)
        else
            synced && _force_fetchtrades(s, ai, o)
            if isempty(order_trades)
                @debug "market order: no trades yet" synced
                missing
            else
                last(order_trades)
            end
        end
    end
end
