
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
    eid = exchangeid(ai)
    open_orders = fetch_open_orders(s, ai; side)
    maxout!(s, ai)
    live_orders = Set{String}()
    default_pos = get_position_side(s, ai)
    for resp in open_orders
        pos = _ccxtposside(resp, eid, Val(:order), def=default_pos)
        o = (@something findorder(s, ai, resp) create_live_order(
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
        push!(s.holdings, ai)
        push!(live_orders, o.id)

        replay_order!(s, o, ai; resp)
    end
    for o in values(s)
        o.id ∉ live_orders && delete!(s, ai, o)
    end
    if orderscount(s, ai) > 0
        watch_trades!(s, ai) # ensure trade watcher is running
        watch_orders!(s, ai) # ensure orders watcher is running
    end
    nothing
end

function findorder(s, ai, resp)
    id = resp_order_id(resp, exchangeid(ai), String)
    if !isempty(id)
        side = @something _ccxt_sidetype(resp, exchangeid(ai); getter=resp_order_side) Both
        for o in values(s, ai, side)
            if o.id == id
                return o
            end
        end
        o = findfirst(t -> t.order.id == id, ai.history)
        if o isa Order
            return o
        end
    end
end

function replay_order!(s::LiveStrategy, o, ai; resp)
    state = set_active_order!(s, ai, o)
    if ismissing(state)
        @error "Expected active order state to be present already."
        return o
    end
    order_trades = PyList(resp_order_trades(resp, exchangeid(ai)))
    new_trades = @view order_trades[(begin + length(trades(o))):end]
    if !isempty(new_trades)
        for trade_resp in new_trades
            trade = maketrade(s, o, ai; resp=trade_resp)
            apply_trade!(s, ai, o, trade)
        end
    else
        trade = emulate_trade!(s, o, ai; state, resp, exec=false)
        isnothing(trade) || apply_trade!(s, ai, o, trade)
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
    try
        lock.(s.universe)
        eid = exchangeid(s)
        local_ids = Set(o.id for o in values(s))
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
    finally
        unlock.(s.universe)
    end
end
