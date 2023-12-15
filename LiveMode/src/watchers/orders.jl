import .PaperMode: SimMode
using .Executors: filled_amount, orderscount, orders
using .Executors: isfilled as isorder_filled
using .Instances: ltxzero, gtxzero
using .SimMode: @maketrade

# TODO: `watch_orders!` and `watch_trades!` currently operate on one symbol only.
# This could be improved by batching new tasks called within a short amount time
# and use the `...ForSymbols` functions from ccxt.

@doc """ Watches and manages orders for a live strategy with an asset instance.

$(TYPEDSIGNATURES)

This function watches orders for a live strategy `s` with an asset instance `ai`. It starts a task that continuously fetches the latest orders from the exchange and updates the live strategy's order list.
First, it fetches the latest orders from the exchange using the asset instance `ai`. It then goes through each fetched order and checks if it already exists in the live strategy's order list. If it does, the function updates the existing order with the latest information. If it doesn't, the function adds the new order to the list.
In addition, this function also manages order statuses. If an order's status has changed (e.g., from 'open' to 'closed'), it updates the status in the live strategy's order list.
Any additional keyword arguments (`exc_kwargs`) are passed to the asset instance, which can use them to customize its behavior.
The function handles exceptions gracefully. If an exception occurs during the fetch orders operation, it logs the exception and continues with the next iteration.

"""
function watch_orders!(s::LiveStrategy, ai; exc_kwargs=())
    tasks = asset_tasks(s, ai)
    @lock tasks.lock begin
        @deassert tasks.byname === asset_tasks(s, ai).byname
        let task = asset_orders_task(tasks.byname)
            istaskrunning(task) && return task
        end
        exc = exchange(ai)
        orders_byid = active_orders(s, ai)
        stop_delay = Ref(Second(60))
        task = @start_task orders_byid begin
            (f, iswatch) = if has(exc, :watchOrders)
                let sym = raw(ai), func = exc.watchOrders
                    (
                        (flag, coro_running) -> if flag[]
                            pyfetch(func, sym; coro_running, exc_kwargs...)
                        end,
                        true,
                    )
                end
            else
                _, other_exc_kwargs = splitkws(:since; kwargs=exc_kwargs)
                since = Ref(now())
                since_start = since[]
                eid = exchangeid(ai)
                (
                    (_, _) -> begin
                        since[] == since_start || sleep(1)
                        resp = fetch_orders(
                            s, ai; since=dtstamp(since[]) + 1, other_exc_kwargs...
                        )
                        if !isnothing(resp) && islist(resp) && length(resp) > 0
                            since[] = @something pytodate(resp[-1], eid) now()
                        end
                        resp
                    end,
                    false,
                )
            end
            queue = tasks.queue
            flag = TaskFlag()
            coro_running = pycoro_running(flag)
            cond = task_local_storage(:notify)
            sem = task_sem()
            handler_tasks = Task[]
            while istaskrunning()
                try
                    while istaskrunning()
                        updates = f(flag, coro_running)
                        stop_delay[] = Second(60)
                        if updates isa InterruptException
                            throw(updates)
                        elseif updates isa Exception
                            @ifdebug ispyminor_error(updates) ||
                                @debug "Error fetching orders (using watch: $(iswatch))" updates
                            sleep(1)
                        else
                            !islist(updates) && (updates = pylist(updates))
                            for resp in updates
                                ht = @async handle_order!(s, ai, orders_byid, resp, sem)
                                push!(handler_tasks, ht)
                            end
                            safenotify(cond)
                        end
                        filter!(istaskrunning, handler_tasks)
                    end
                catch e
                    if e isa InterruptException
                        rethrow(e)
                    else
                        @debug "orders watching for $(raw(ai)) resulted in an error (possibly a task termination through running flag)."
                        @debug_backtrace
                    end
                    sleep(1)
                end
            end
        end
        cond = task.storage[:notify]
        stop_task = @async begin
            task_local_storage(:sleep, 10)
            task_local_storage(:running, true)
            while istaskrunning()
                safewait(cond)
                sleep(stop_delay[])
                stop_delay[] = Second(0)
                # if there are no more orders, stop the monitoring tasks
                if orderscount(s, ai) == 0 && !isactive(s, ai)
                    task_local_storage(:running, false)
                    try
                        @debug "Stopping orders watcher for $(raw(ai))@($(nameof(s)))" current_task()
                        @lock tasks.lock begin
                            stop_watch_orders!(s, ai)
                            # also stop the trades task if running
                            if hasmytrades(exchange(ai))
                                @debug "Stopping trades watcher for $(raw(ai))@($(nameof(s)))"
                                stop_watch_trades!(s, ai)
                            end
                        end
                    finally
                        break
                    end
                end
            end
        end
        try
            tasks.byname[:orders_task] = task
            tasks.byname[:orders_stop_task] = stop_task
            task
        catch
            task
        end
    end
end

asset_orders_task(tasks) = get(tasks, :orders_task, nothing)
@doc """ Retrieves the orders task for a given asset instance.

$(TYPEDSIGNATURES)

This function retrieves the orders task for a given asset instance `ai` from the live strategy `s`. The orders task is responsible for watching and updating orders for the asset instance.

"""
asset_orders_task(s, ai) = asset_orders_task(asset_tasks(s, ai).byname)
asset_orders_stop_task(tasks) = get(tasks, :orders_stop_task, nothing)
@doc """ Retrieves the orders stop task for a given asset instance.

$(TYPEDSIGNATURES)

This function retrieves the orders stop task for a given asset instance `ai` from the live strategy `s`. The orders stop task is responsible for stopping the watching and updating of orders for the asset instance.

"""
asset_orders_stop_task(s, ai) = asset_orders_stop_task(asset_tasks(s, ai).byname)

@doc """ Generates a unique enough hash for an order. """
function _order_kv_hash(resp, eid::EIDType)
    p1 = resp_order_price(resp, eid, Py)
    p2 = resp_order_timestamp(resp, eid, Py)
    p3 = resp_order_stop_price(resp, eid)
    p4 = resp_order_trigger_price(resp, eid)
    p5 = resp_order_amount(resp, eid, Py)
    p6 = resp_order_cost(resp, eid, Py)
    p7 = resp_order_average(resp, eid, Py)
    p8 = resp_order_filled(resp, eid, Py)
    p9 = resp_order_remaining(resp, eid, Py)
    p10 = resp_order_status(resp, eid)
    p10 = resp_order_loss_price(resp, eid)
    p10 = resp_order_profit_price(resp, eid)
    p11 = resp_order_lastupdate(resp, eid)
    hash((p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11))
end

@doc """ Stops the orders watcher for an asset instance. """
function stop_watch_orders!(s::LiveStrategy, ai)
    asset_orders_stop_task(s, ai) |> stop_task
    asset_orders_task(s, ai) |> stop_task
end

@doc """ Generates a unique enough hash for an order, preferably based on the last update, or the order info otherwise. """
order_update_hash(resp, eid) = begin
    last_update = resp_order_lastupdate(resp, eid)
    if pyisnone(last_update)
        info = resp_order_info(resp, eid)
        if pyisnone(info)
            _order_kv_hash(resp, eid)
        else
            pydicthash(info)
        end
    else
        hash(last_update)
    end
end

@doc """ Updates an existing order in the system.

$(TYPEDSIGNATURES)

This function updates the state of an order in the system based on the new information received. 
It locks the state and updates the hash of the order. 
If the order is still open, it emulates the trade. 
If the order is filled or not open anymore, it finalizes the order, waits for trades to be processed if necessary, and removes it from the active orders map. 
If the order did not complete, it sends an error and cancels the order.
"""
function update_order!(s, ai, eid; resp, state)
    @debug "update ord: locking state" id = state.order.id islocked(ai) f = @caller 7
    @lock state.lock begin
        @debug "update ord: locked" id = state.order.id islocked(ai)
        this_hash = order_update_hash(resp, eid)
        state.update_hash[] == this_hash && return nothing
        # always update hash on new data
        state.update_hash[] = this_hash
        # only emulate trade if trade watcher task
        # is not running
        if hasmytrades(exchange(ai))
        else
            @debug "update ord: locking ai" ai = raw(ai) side = posside(state.order) id =
                state.order.id
            @lock ai if isopen(ai, state.order)
                t = emulate_trade!(s, state.order, ai; state.average_price, resp)
                @debug "update ord: emulated trade" trade = t id = state.order.id
            end
        end
        # if order is filled remove it from the task orders map.
        # Also remove it if the order is not open anymore (closed, cancelled, expired, rejected...)
        order_open = _ccxtisopen(resp, eid)
        order_closed = _ccxtisclosed(resp, eid)
        order_trades = trades(state.order)
        order_filled = isorder_filled(ai, state.order)

        if order_filled || !order_open
            # Wait for trades to be processed if trades are not emulated
            @debug "update ord: finalizing" is_synced = isorder_synced(
                state.order, ai, resp
            ) n_trades = length(order_trades) last_trade = if isempty(order_trades)
                nothing
            else
                last(order_trades).date
            end resp_date = pytodate(resp, exchangeid(ai)) local_filled = filled_amount(
                state.order
            ) resp_filled = resp_order_filled(resp, eid) local_trades = length(
                trades(state.order)
            ) remote_trades = length(resp_order_trades(resp, eid)) status = resp_order_status(
                resp, eid
            )

            if hasmytrades(exchange(ai))
                trades_count = length(order_trades)
                if (order_filled && trades_count == 0) ||
                    !isorder_synced(state.order, ai, resp)
                    @debug "update ord: waiting for trade events" id = state.order.id
                    waitfortrade(s, ai, state.order; waitfor=Second(1))
                    if length(order_trades) == trades_count
                        @lock ai if isopen(ai, state.order)
                            @warn "update ord: falling back to emulation." locked = islocked(
                                ai
                            ) trades_count
                            @debug "update ord: emulating trade" id = state.order.id
                            t = emulate_trade!(
                                s, state.order, ai; state.average_price, resp
                            )
                            @debug "update ord: emulation done" trade = t id =
                                state.order.id
                        end
                    end
                end
            end
            # Order did not complete, send an error
            if !order_closed
                cancel!(
                    s,
                    state.order,
                    ai;
                    err=OrderFailed(resp_order_status(resp, eid, String)),
                )
            end
            @debug "update ord: de activating order" id = state.order.id ai = raw(ai)
            clear_order!(s, ai, state.order)
            @ifdebug if hasorders(s, ai, state.order.id)
                @warn "update ord: order should already have been removed from local state, \
                possible emulation problem" id = state.order.id order_trades = trades(
                    state.order
                )
            end
        end
    end
end

@doc """ Re-activates a previously active order.

$(TYPEDSIGNATURES)

This function attempts to re-activate an order that was previously active in the system.
If the order is still open, it updates the order state. 
If the order cannot be found or re-created, it cancels the order from the exchange and removes it from the local state if present.

"""
function re_activate_order!(s, ai, id; eid, resp)
    function docancel(o=nothing)
        @error "reactivate ord: could not re-create order, cancelling from exchange" id exc = nameof(
            exchange(ai)
        )
        live_cancel(s, ai; ids=(id,), confirm=false, all=false)
        if o isa Order && hasorders(s, ai, o.id)
            cancel!(
                s,
                o,
                ai;
                err=OrderFailed("Dangling order $id found in local state ($(raw(ai)))."),
            )
        end
    end

    o = findorder(s, ai; resp, id)
    # This should practically never happen
    if o isa Order && isopen(ai, o)
        state = set_active_order!(s, ai, o)
        @warn "reactivate ord: re-activation done" id exc = nameof(exchange(ai))
        if state isa LiveOrderState
            update_order!(s, ai, eid; resp, state)
        else
            docancel(o)
        end
    else
        o = create_live_order(
            s,
            resp,
            ai;
            t=get_position_side(s, ai),
            price=missing,
            amount=missing,
            synced=false,
        )
        if o isa Order
            state = get_order_state(active_orders(s, ai), o.id)
            if state isa LiveOrderState
                update_order!(s, ai, eid; resp, state)
            else
                docancel(o)
            end
        else
            docancel()
        end
    end
end

@doc """Manages the lifecycle of an order event.

$(TYPEDSIGNATURES)

The function extracts an order id from the `resp` object and based on the status of the order, it either updates, re-activates, or cancels the order. 
It uses a semaphore to ensure the order of events is respected.
"""
function handle_order!(s, ai, orders_byid, resp, sem)
    try
        @debug "handle ord: new event" sem = length(sem)
        eid = exchangeid(ai)
        id = resp_order_id(resp, eid, String)
        isprocessed_order(s, ai, id) && return nothing
        @debug "handle ord: this event" id = id status = resp_order_status(resp, eid)
        if isempty(id)
            @warn "handle ord: missing order id"
            return nothing
        else
            # TODO: we could repllace the queue with the handler_tasks vector
            # since the order is the same
            # remember events order
            n = isempty(sem.queue) ? 1 : last(sem.queue) + 1
            push!(sem.queue, n)
            try
                state = get_order_state(orders_byid, id)
                # wait for earlier events to be processed
                while first(sem.queue) != n
                    @debug "handle ord: waiting for queue" n id
                    safewait(sem.cond)
                end
                if state isa LiveOrderState
                    @debug "handle ord: updating" id ai = raw(ai)
                    update_order!(s, ai, eid; resp, state)
                elseif _ccxtisopen(resp, eid)
                    @debug "handle ord: re-activating (open) order" id ai = raw(ai)
                    re_activate_order!(s, ai, id; eid, resp)
                else
                    for o in values(s, ai) # ensure order is not stored locally
                        if o.id == id
                            @debug "handle ord: cancelling local order since non open remotely" id ai = raw(
                                ai
                            ) s = nameof(s)
                            cancel!(
                                s,
                                o,
                                ai;
                                err=OrderFailed(
                                    "Dangling order $id found in local state ($(raw(ai)))."
                                ),
                            )
                            break # do not expect duplicates
                        end
                    end
                end
            finally
                idx = findfirst(x -> x == n, sem.queue)
                isnothing(idx) || deleteat!(sem.queue, idx)
                safenotify(sem.cond)
            end
        end
    catch e
        @ifdebug isdefined(Main, :e) && (Main.e[] = e)
        @debug_backtrace
        ispyminor_error(e) || @error e
    end
end

@doc """Emulates a trade based on order and response objects.

$(TYPEDSIGNATURES)

This function checks if an order is open, validates the order details (type, symbol, id, side), and calculates the filled amount. 
If the filled amount has changed, it computes the new average price and checks if it's within the limits. 
It then emulates the trade and updates the order state.
"""
function emulate_trade!(s::LiveStrategy, o, ai; resp, average_price=Ref(o.price), exec=true)
    isopen(ai, o) || begin
        @error "emu trade: closed order ($(o.id))"
        return nothing
    end
    eid = exchangeid(ai)
    check_type(ai, o, resp, eid) || return nothing
    check_symbol(ai, o, resp, eid) || return nothing
    check_id(ai, o, resp, eid; getter=resp_order_id) || return nothing
    side = _ccxt_sidetype(resp, eid; o)
    _check_side(side, o) || return nothing
    new_filled = resp_order_filled(resp, eid)
    prev_filled = filled_amount(o)
    actual_amount = new_filled - prev_filled
    ltxzero(ai, actual_amount, Val(:amount)) && begin
        @debug "emu trade: fill status unchanged" o.id prev_filled new_filled actual_amount
        return nothing
    end
    prev_cost = average_price[] * prev_filled
    (net_cost, actual_price) = let ap = resp_order_average(resp, eid)
        if ap > zero(ap)
            net_cost = let c = resp_order_cost(resp, eid)
                iszero(c) ? ap * actual_amount : c
            end
            this_price = (ap - prev_cost) / actual_amount
            average_price[] = ap
            (net_cost, this_price)
        else
            this_cost = resp_order_cost(resp, eid)
            if iszero(this_cost)
                @error "emu trade: unavailable fields (average or cost)" ai = raw(ai) exc = nameof(
                    exchange(ai)
                )
                (ZERO, ZERO)
            else
                prev_cost = average_price[] * prev_filled
                net_cost = this_cost - prev_cost
                if net_cost < ai.limits.cost.min
                    @error "emu trade: net cost below min" ai = raw(ai) net_cost
                    (ZERO, ZERO)
                else
                    average_price[] = (prev_cost + net_cost) / new_filled
                    (net_cost, net_cost / actual_amount)
                end
            end
        end
    end
    _check_price(s, ai, actual_price, o; resp) || return nothing
    check_limits(actual_price, ai, :price) || return nothing
    check_limits(net_cost, ai, :cost) || return nothing
    check_limits(actual_amount, ai, :amount) || return nothing

    @debug "emu trade: emulating" id = o.id
    _warn_cash(s, ai, o; actual_amount)
    date = @something pytodate(resp, eid) now()
    fees_quote, fees_base = _tradefees(
        resp, orderside(o), ai; actual_amount=actual_amount, net_cost=net_cost
    )
    size = _addfees(net_cost, fees_quote, o)
    trade = @maketrade
    if exec
        queue = asset_queue(s, ai)
        try
            inc!(queue)
            trade!(
                s,
                o,
                ai;
                resp,
                trade,
                date=nothing,
                price=nothing,
                actual_amount=nothing,
                fees=nothing,
                slippage=false,
            )
        finally
            dec!(queue)
        end
    else
        trade
    end
end

@doc """Waits for any order event to happen on the specified asset.

$(TYPEDSIGNATURES)

This function waits for a specified amount of time or until an order event happens. 
It keeps track of the number of orders and checks if any new order has been added during the wait time. 
If the task is not running, it stops waiting and returns the time spent waiting.
"""
function waitfororder(s::LiveStrategy, ai; waitfor=Second(3))
    aot = @something asset_orders_task(s, ai) watch_orders!(s, ai) missing
    ismissing(aot) && return 0
    timeout = Millisecond(waitfor).value
    cond = aot.storage[:notify]
    prev_count = orderscount(s, ai)
    slept = 0
    @debug "Wait for any order" ai = raw(ai) waitfor
    while slept < timeout
        if istaskrunning(aot)
            slept += waitforcond(cond, timeout - slept)
            orderscount(s, ai) != prev_count && begin
                @debug "New order event" ai = raw(ai) slept
                break
            end
        else
            @error "Wait for order: orders task is not running" ai = raw(ai)
            break
        end
    end
    slept
end

@doc """ Waits for a specific order to be processed. 

$(TYPEDSIGNATURES)

This function waits for a specific order to be processed within a given time frame specified by `waitfor`. 
If the order is not found or not tracked within the given timeframe, the function returns `false`.
If the order is found and tracked within the given timeframe, the function returns `true`.
It tracks the time spent waiting and if the timeout is reached before the order is found, the function returns `false`.

"""
function waitfororder(s::LiveStrategy, ai, o::Order; waitfor=Second(3))
    slept = 0
    timeout = Millisecond(waitfor).value
    orders_byid = active_orders(s, ai)
    (haskey(orders_byid, o.id) && haskey(s, ai, o)) || return false
    @debug "Wait for order: start" id = o.id timeout = timeout
    while slept < timeout
        slept += waitfororder(s, ai; waitfor)
        if !haskey(orders_byid, o.id)
            @ifdebug if isimmediate(o) && isempty(trades(o))
                @warn "Wait for order: immediate order has no trades"
            end
            @debug "Wait for order: not tracked" id = o.id
            return true
        elseif !haskey(s, ai, o)
            @debug "Wait for order: not found" id = o.id
            return true
        end
        slept < timeout || begin
            @debug "Wait for order: timedout" o.id timeout
            return false
        end
    end
    return false
end
