
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

function live_sync_active_orders!(s::LiveStrategy, ai; create_kwargs=(;), side=Both)
    ao = active_orders(s, ai)
    if !isempty(ao)
        @warn "Active orders dict found not empty, deleting $(length(ao)) entries."
        empty!(ao)
    end
    if orderscount(s) > 0
        @warn "$(orderscount(s)) in the local state of the strategy, deleting $(length(ao)) entries."
        foreach(ai -> delete!(s, ai), s.universe)
    end
    eid = exchangeid(ai)
    open_orders = fetch_open_orders(s, ai; side)
    pos = get_position_side(s, ai)
    maxout!(s, ai)
    for resp in open_orders
        o = (@something findorder(ai, resp) create_live_order(
            s,
            resp,
            ai;
            t=pos,
            price=missing,
            amount=missing,
            retry_with_resync=false,
            create_kwargs...,
        ) missing)::Option{O where O<:Order}
        ismissing(o) && continue
        replay_order!(s, o, ai; resp)
    end
    if orderscount(s, ai) > 0
        watch_trades!(s, ai) # ensure trade watcher is running
        watch_orders!(s, ai) # ensure orders watcher is running
    end
    nothing
end

function findorder(ai, resp)
    id = resp_order_id(resp, exchangeid(ai), String)
    if !isempty(id)
        findfirst(t -> t.order.id == id, ai.history)
    end
end

function replay_order!(s::LiveStrategy, o, ai; resp)
    ao = active_orders(s, ai)
    state = get_order_state(ao, o.id; waitfor=Second(0))
    order_trades = PyList(resp_order_trades(resp, exchangeid(ai)))
    new_trades = @view order_trades[(begin + length(trades(o))):end]
    if !isempty(new_trades)
        for trade_resp in new_trades
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

function check_orders_sync(s::LiveStrategy)
    eid = exchangeid(s)
    local_ids = Set(o.id for (_, o) in Executors.orders(s))
    exc_ids = Set{String}()
    tracked_ids = Set{String}()
    @sync for ai in s.universe
        @async for o in fetch_open_orders(s, ai)
            push!(exc_ids, resp_order_id(o, eid, String))
        end
        for id in keys(active_orders(s, ai))
            push!(tracked_ids, id)
        end
    end
    @assert length(tracked_ids) == length(exc_ids)
    @assert length(local_ids) == length(exc_ids)
    @assert all(id ∈ exc_ids for id in local_ids)
    @assert all(id ∈ exc_ids for id in tracked_ids)
    @info "Currently tracking $(length(tracked_ids)) orders"
end
