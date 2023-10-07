using .Executors: _cashfrom

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

_amount_from_trades(trades) = sum(t.amount for t in trades)

function live_sync_open_orders!(
    s::LiveStrategy, ai; strict=true, exec=false, create_kwargs=(;), side=Both
)
    ao = active_orders(s, ai)
    eid = exchangeid(ai)
    open_orders = fetch_open_orders(s, ai; side)
    if isnothing(open_orders)
        @error "sync orders: couldn't fetch open orders, skipping sync" ai = raw(ai) s = nameof(
            s
        )
        return nothing
    end
    # Pre-delete local orders not open on exc to fix commit calculation
    let exc_ids = Set(resp_order_id(resp, eid) for resp in open_orders)
        for o in values(s, ai, side)
            o.id ∉ exc_ids && delete!(s, ai, o)
        end
    end
    live_orders = Set{String}()
    @ifdebug begin
        cash_long = cash(ai, Long())
        comm_long = committed(ai, Long())
        cash_short = cash(ai, Short())
        comm_short = committed(ai, Short())
    end
    @debug "sync orders: syncing" islocked(ai) length(open_orders)
    @lock ai begin
        default_pos = get_position_side(s, ai)
        strict && maxout!(s, ai)
        for resp in open_orders
            id = resp_order_id(resp, eid, String)
            o = (@something get(ao, id, nothing) findorder(
                s, ai; id, side, resp
            ) create_live_order(
                s,
                resp,
                ai;
                t=_ccxtposside(s, resp, eid; def=default_pos),
                price=missing,
                amount=missing,
                synced=false,
                skipcommit=(!strict),
                withoutkws(:skipcommit; kwargs=create_kwargs)...,
            ) missing)::Option{Order}
            ismissing(o) && continue
            if isfilled(ai, o)
                isapprox(ai, _amount_from_trades(trades(o)), o.amount, Val(:amount)) ||
                    begin
                        @debug "sync orders: replaying filled order with no trades"
                        replay_order!(s, o, ai; resp, exec=false)
                    end
                @debug "sync orders: removing filled active order" o.id o.amount trades_amount = _amount_from_trades(
                    trades(o)
                ) ai = raw(ai) s = nameof(s)
                delete!(ao, o.id)
            else
                @debug "sync orders: setting active order" o.id ai = raw(ai) s = nameof(s)
                push!(live_orders, o.id)
                replay_order!(s, o, ai; resp, exec)
                if isfilled(ai, o)
                    delete!(ao, o.id)
                elseif filled_amount(o) > ZERO && o isa IncreaseOrder
                    @ifdebug if ai ∉ s.holdings
                        @debug "sync orders: asset not in holdings" ai = raw(ai)
                    end
                    push!(s.holdings, ai)
                end
            end
        end
    end
    for o in values(s, ai, side)
        if o.id ∉ live_orders
            @debug "sync orders: local order non open on exchange." o.id ai = raw(ai) exc = nameof(
                exchange(ai)
            )
            delete!(s, ai, o)
        end
    end
    @sync for (id, state) in ao
        orderside(state.order) == side || continue
        if id ∉ live_orders
            @debug "sync orders: tracked local order was not open on exchange" id ai = raw(
                ai
            ) exc = nameof(exchange(ai))
            @deassert id == state.order.id
            @async @lock ai if isopen(ai, state.order) # need to sync trades
                order_resp = try
                    resp = fetch_orders(s, ai; ids=(id,))
                    if islist(resp) && !isempty(resp)
                        resp[0]
                    elseif isdict(resp)
                        resp
                    end
                catch
                    @debug_backtrace
                end
                if isdict(order_resp)
                    @deassert resp_order_id(order_resp, eid, String) == id
                    replay_order!(s, state.order, ai; resp=order_resp, exec)
                else
                    @error "sync orders: local order not found on exchange" id ai = raw(ai) exc = nameof(
                        exchange(ai)
                    ) resp = order_resp
                end
                delete!(ao, id)
            else
                delete!(ao, id)
            end
        end
    end
    @deassert orderscount(s, ai, side) == length(live_orders)
    if orderscount(s, ai, side) > 0
        watch_trades!(s, ai) # ensure trade watcher is running
        watch_orders!(s, ai) # ensure orders watcher is running
    end
    # @ifdebug @debug "" cash_long cash_short comm_long comm_short
    @ifdebug @assert strict || all((
        cash_long == cash(ai, Long()),
        comm_long == committed(ai, Long()),
        cash_short == cash(ai, Short()),
        comm_short == committed(ai, Short()),
    ))
    strict && @warn "sync orders: strategy and assets cash need to be re-synced." maxlog = 1
    nothing
end

function findorder(
    s,
    ai;
    resp=nothing,
    id=resp_order_id(resp, exchangeid(ai), String),
    side=@something(_ccxt_sidetype(resp, exchangeid(ai); getter=resp_order_side), Both)
)
    if !isempty(id)
        for o in values(s, ai, side)
            if o.id == id
                @deassert o isa Order
                return o
            end
        end
        history = trades(ai)
        t = findfirst((t -> t.order.id == id), history)
        if t isa Integer
            return history[t].order
        else
            # @debug "find order: not found" resp id t
        end
    end
end

function replay_order!(s::LiveStrategy, o, ai; resp, exec=false, insert=false)
    eid = exchangeid(ai)
    state = set_active_order!(s, ai, o; ap=resp_order_average(resp, eid))
    if iszero(resp_order_filled(resp, eid))
        iszero(filled_amount(o)) || reset!(o, ai)
        @debug "replay order: order unfilled (returning)"
        return o
    end
    if ismissing(state)
        @error "replay order: order state not found"
        return o
    end
    local_trades = trades(o)
    local_count = length(local_trades)
    # Try to get order trades from order struct first
    # otherwise from api call
    order_trades = let otr = resp_order_trades(resp, eid)
        if isempty(otr)
            otr = fetch_order_trades(s, ai, o.id)
        else
            otr
        end |> PyList
    end
    # Sanity check between local and exc trades by
    # comparing the amount of the first trade
    if length(order_trades) > 0 && local_count > 0
        trade = first(order_trades)
        local_amt = abs(first(trades(o)).amount)
        resp_amt = resp_trade_amount(trade, eid)
        # When a mismatch happens we reset local state for the order
        if isapprox(ai, local_amt, resp_amt, Val(:amount))
            @warn "replay order: mismatching amounts (resetting)" local_amt resp_amt o.id ai = raw(
                ai
            ) exc = nameof(exchange(ai))
            local_count = 0
            # remove trades from asset trades history
            filter!(t -> t.order !== o, trades(ai))
            # reset order
            reset!(o, ai)
        end
    end
    new_trades = @view order_trades[(begin + local_count):end]
    if isempty(new_trades)
        @debug "replay order: emulating trade"
        trade = emulate_trade!(s, o, ai; state.average_price, resp, exec)
        exec || isnothing(trade) || apply_trade!(s, ai, o, trade; insert)
    else
        @debug "replay order: replaying trades"
        for trade_resp in new_trades
            if exec
                trade!(
                    s,
                    state.order,
                    ai;
                    resp=trade_resp,
                    date=nothing,
                    price=nothing,
                    actual_amount=nothing,
                    fees=nothing,
                    slippage=false,
                )
            else
                trade = maketrade(s, o, ai; resp=trade_resp)
                @debug "replay order: applying new trade" trade.order.id
                apply_trade!(s, ai, o, trade; insert)
            end
        end
    end
    o
end

function aftertrade_nocommit!(s, ai, o::AnyLimitOrder, _)
    if isfilled(ai, o)
        delete!(s, ai, o)
    end
end
function aftertrade_nocommit!(s, ai, o::Union{AnyFOKOrder,AnyIOCOrder}, _)
    delete!(s, ai, o)
    isfilled(ai, o) || ping!(s, o, NotEnoughCash(_cashfrom(s, ai, o)), ai)
end
aftertrade_nocommit!(_, _, o::AnyMarketOrder, args...) = nothing
@doc """ Similar to `trade!` but doesn't update cash.


"""
function apply_trade!(s::LiveStrategy, ai, o, trade; insert=false)
    isnothing(trade) && return nothing
    fill!(s, ai, o, trade)
    if insert
        history = trades(ai)
        idx = searchsorted(history, trade; by=t -> t.date)
        if length(idx) > 0
            insert!(history, idx.first > 0 ? idx.first : idx.second, trade)
        end
    else
        push!(ai.history, trade)
    end
    @deassert trade.order == o
    @ifdebug let found = findorder(s, ai; id=o.id, side=orderside(o))
        if found != o
            @error "replay order: duplicate" found o
        end
    end
    push!(trades(o), trade)
    aftertrade_nocommit!(s, ai, o, trade)
end

function live_sync_open_orders!(s::LiveStrategy; kwargs...)
    @sync for ai in s.universe
        @async live_sync_open_orders!(s, ai; kwargs...)
    end
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
        if length(tracked_ids) != length(exc_ids)
            @error "Tracked ids not matching exchange ids" non_exc_ids = Set(
                id for id in tracked_ids if id ∉ exc_ids
            ) non_tracked_ids = Set(id for id in exc_ids if id ∉ tracked_ids)
        end
        if length(local_ids) != length(exc_ids)
            @error "Local ids not matching exchange ids" non_exc_ids = Set(
                id for id in local_ids if id ∉ exc_ids
            ) non_local_ids = Set(id for id in exc_ids if id ∉ local_ids)
        end
        @assert all(id ∈ exc_ids for id in local_ids)
        @assert all(id ∈ exc_ids for id in tracked_ids)
        @info "Currently tracking $(length(tracked_ids)) orders"
    finally
        unlock.(s.universe)
    end
end

function live_sync_closed_orders!(s::LiveStrategy, ai; create_kwargs=(;), side=Both, kwargs...)
    eid = exchangeid(ai)
    closed_orders = fetch_closed_orders(s, ai; side, kwargs...)
    if isnothing(closed_orders)
        @error "sync orders: couldn't fetch closed orders, skipping sync" ai = raw(ai) s = nameof(
            s
        )
        return nothing
    end
    @lock ai begin
        default_pos = get_position_side(s, ai)
        @sync for resp in closed_orders
            @async begin
                id = resp_order_id(resp, eid, String)
                o = (@something findorder(s, ai; resp, id, side) create_live_order(
                    s,
                    resp,
                    ai;
                    t=_ccxtposside(s, resp, eid; def=default_pos),
                    price=missing,
                    amount=missing,
                    synced=false,
                    skipcommit=true,
                    activate=false,
                    withoutkws(:skipcommit; kwargs=create_kwargs)...,
                ) missing)::Option{Order}
                if ismissing(o)
                else
                    @deassert resp_order_status(resp, eid, String) ∈
                        ("closed", "open", "cancelled")
                    @ifdebug trades_count = length(ai.history)
                    if isfilled(ai, o)
                        @deassert !isempty(trades(o))
                    else
                        replay_order!(s, o, ai; resp, exec=false)
                        @deassert length(ai.history) > trades_count
                    end
                    delete!(s, ai, o)
                    @deassert !hasorders(s, ai, o.id)
                end
            end
        end
    end
end

function live_sync_closed_orders!(s::LiveStrategy; kwargs...)
    @sync for ai in s.universe
        @async live_sync_closed_orders!(s, ai; kwargs...)
    end
end
