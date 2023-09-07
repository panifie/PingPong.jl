
# Before syncing orders, set cash of both strategy and asset instance to maximum to avoid failing order creation.
maxout!(s::LiveStrategy, ai) = begin
    # Strategy
    v = s.cash.value
    cash!(s.cash, typemax(v))
    cash!(s.cash_committed, zero(v))
    if ai isa MarginInstance
        # Asset Long
        c = cash(ai, Long())
        cm = committed(ai, Long())
        cash!(c, typemax(c.value))
        cash!(cm, zero(c.value))
        # Asset Short
        c = cash(ai, Short())
        cm = committed(ai, Short())
        cash!(c, typemin(c.value))
        cash!(cm, zero(c.value))
    else
        c = cash(ai)
        cm = committed(ai)
        cash!(c, typemax(c.value))
        cash!(cm, zero(c.value))
    end
end

function live_sync_active_orders!(s::LiveStrategy, ai; create_kwargs=(;))
    ao = active_orders(s, ai)
    if !isempty(ao)
        @warn "Active orders dict found not empty, deleting $(length(ao)) entries."
        empty!(ao)
    end
    eid = exchangeid(ai)
    open_orders = fetch_open_orders(s, ai)
    pos = get_position_side(s, ai)
    maxout!(s, ai)
    for resp in open_orders
        o = create_live_order(
            s,
            resp,
            ai;
            t=pos,
            price=missing,
            amount=missing,
            retry_with_resync=false,
            create_kwargs...,
        )
        isnothing(o) && continue
        replay_order!(s, o, ai; resp)
    end
    if orderscount(s, ai) > 0
        watch_trades!(s, ai) # ensure trade watcher is running
        watch_orders!(s, ai) # ensure orders watcher is running
    end
    nothing
end

function replay_order!(s::LiveStrategy, o, ai; resp)
    ao = active_orders(s, ai)
    state = get_order_state(ao, o.id; waitfor=Second(0))
    order_trades = resp_order_trades(resp, exchangeid(ai))
    if !isempty(order_trades)
        for trade_resp in order_trades
            trade = maketrade(s, o, ai; resp=trade_resp)
            apply_trade!(s, ai, o, trade)
        end
    else
        trade = emulate_trade!(s, o, ai; state, resp, exec=false)
        apply_trade!(s, ai, o, trade)
    end
    o
end

@doc """ Similar to `trade!` but doesn't update cash.


"""
apply_trade!(s::LiveStrategy, ai, o, trade) = begin
    isnothing(trade) && return nothing
    fill!(s, ai, o, trade)
    push!(ai.history, trade)
    push!(trades(o), trade)
    aftertrade!(s, ai, o, trade)
end

function live_sync_active_orders!(s::LiveStrategy; kwargs...)
    @sync for ai in s.universe
        @async live_sync_active_orders!(s, ai; kwargs...)
    end
    @info "Cash sync is required after orders sync."
end
