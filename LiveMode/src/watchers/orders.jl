import .PaperMode: SimMode
using .Executors: filled_amount, orderscount, orders
using .Executors: isfilled as isorder_filled
using .Instances: ltxzero, gtxzero
using .OrderTypes: ReduceOnlyOrder
using .SimMode: @maketrade

# TODO: `watch_orders!` and `watch_trades!` currently operate on one symbol only.
# This could be improved by batching new tasks called within a short amount time
# and use the `...ForSymbols` functions from ccxt.

"""
Initialize necessary tasks and variables for watching orders.
"""
function initialize_watch_tasks!(s::LiveStrategy, ai)
    orders_byid = active_orders(s, ai)
    stop_delay = Ref(s.watch_idle_timeout)
    return orders_byid, stop_delay
end

"""
Defines the functions used for watching orders based on the exchange capabilities.
"""
function define_loop_funct(s::LiveStrategy, ai; exc_kwargs=(;))
    watch_func = first(exchange(ai), :watchOrders)
    _, func_kwargs = splitkws(:since; kwargs=exc_kwargs)
    sym = raw(ai)
    if !isnothing(watch_func) && s[:is_watch_orders]
        init_handler() = begin
            buf = Vector{Any}()
            # NOTE: this is NOT a Threads.Condition because we shouldn't yield inside the push function
            # (we can't lock (e.g. by using `safenotify`) must use plain `notify`)
            buf_notify = Condition()
            sizehint!(buf, s[:live_buffer_size])
            task_local_storage(:buf, buf)
            task_local_storage(:buf_notify, buf_notify)
            since = dtstamp(attr(s, :is_start, now()))
            h = @lget! task_local_storage() :handler begin
                coro_func() = watch_func(sym; since, func_kwargs...)
                f_push(v) = begin
                    push!(buf, v)
                    notify(buf_notify)
                end
                stream_handler(coro_func, f_push)
            end
            start_handler!(h)
        end
        get_from_buffer() = begin
            buf = let b = get(@something(current_task().storage, (;)), :buf, nothing)
                if isnothing(b)
                    init_handler()
                    task_local_storage(:buf)
                else
                    b
                end
            end
            while isempty(buf)
                wait(task_local_storage(:buf_notify))
            end
            popfirst!(buf)
        end
        (get_from_buffer, true)
    else
        since = Ref(attr(s, :is_start, now()))
        since_start = since[]
        eid = exchangeid(ai)
        get_from_call() = begin
            since[] == since_start || sleep(1)
            resp = fetch_orders(
                s, ai; since=dtstamp(since[]) + 1, func_kwargs...
            )
            if islist(resp) && !isempty(resp)
                since[] = @something pytodate(resp[-1], eid) now()
            end
            resp
        end
        (get_from_call, false)
    end
end

"""
Manages the order updates by continuously fetching and processing new orders.
"""
function manage_order_updates!(s::LiveStrategy, ai, orders_byid, stop_delay, loop_func, iswatch)
    sem = task_sem()
    process_tasks = Task[]
    idle_timeout = Second(s.watch_idle_timeout)
    try
        while @istaskrunning()
            try
                @debug "watchers orders: loop func" _module = LogWatchOrder
                updates = loop_func()
                process_updates!(s, ai, orders_byid, updates, sem, process_tasks, iswatch)
                stop_delay[] = idle_timeout
            catch e
                handle_order_updates_errors!(e, ai, iswatch)
            end
        end
    finally
        h = get(task_local_storage(), :handler, nothing)
        if !isnothing(h)
            stop_handler!(h)
        end
    end
end

"""
Processes updates for orders, including fetching new orders and updating existing ones.
"""
function process_updates!(s::LiveStrategy, ai, orders_byid, updates, sem, process_tasks, iswatch)
    if updates isa Exception
        if updates isa InterruptException
            throw(updates)
        else
            @ifdebug ispyminor_error(updates) ||
                     @debug "watch orders: fetching error" _module = LogWatchOrder updates
            if !iswatch
                sleep(1)
            end
        end
    else
        for resp in pylist(updates)
            t = @async process_order!(s, ai, orders_byid, resp, sem)
            push!(process_tasks, t)
        end
        # NOTE: use `!istaskdone` because recent tasks
        # might not yet have been scheduled
        filter!(!istaskdone, process_tasks)
    end
end

"""
Handles errors that occur during the order watching process.
"""
function handle_order_updates_errors!(e, ai, iswatch)
    if e isa InterruptException || e isa InvalidStateException
        rethrow(e)
    else
        @debug "watch orders: error (task termination?)" _module = LogWatchOrder raw(ai) istaskrunning() current_task().storage[:running]
        @debug_backtrace LogWatchOrder
    end
    if !iswatch
        sleep(1)
    end
end

"""
Monitors conditions for stopping the watch tasks and performs cleanup.
"""
function monitor_stop_conditions!(s::LiveStrategy, ai, task, stop_delay, tasks)
    task_local_storage(:sleep, 10)
    task_local_storage(:running, true)
    cond = task.storage[:notify]
    while @istaskrunning()
        safewait(cond)
        @istaskrunning() || break
        sleep(stop_delay[])
        stop_delay[] = Second(0)
        @lock ai if orderscount(s, ai) == 0 && !isactive(s, ai)
            task_local_storage(:running, false)
            try
                @debug "Stopping orders watcher for $(raw(ai))@($(nameof(s)))" _module = LogWatchOrder current_task()
                @lock tasks.lock begin
                    stop_watch_orders!(s, ai)
                    # also stop the trades task if running
                    if hasmytrades(exchange(ai))
                        @debug "Stopping trades watcher for $(raw(ai))@($(nameof(s)))" _module = LogWatchTrade
                        stop_watch_trades!(s, ai)
                    end
                end
            finally
                break
            end
        end
    end
end


@doc """ Watches and manages orders for a live strategy with an asset instance.

$(TYPEDSIGNATURES)

This function watches orders for a live strategy `s` with an asset instance `ai`. It starts a task that continuously fetches the latest orders from the exchange and updates the live strategy's order list.
First, it fetches the latest orders from the exchange using the asset instance `ai`. It then goes through each fetched order and checks if it already exists in the live strategy's order list. If it does, the function updates the existing order with the latest information. If it doesn't, the function adds the new order to the list.
In addition, this function also manages order statuses. If an order's status has changed (e.g., from 'open' to 'closed'), it updates the status in the live strategy's order list.
Any additional keyword arguments (`exc_kwargs`) are passed to the asset instance, which can use them to customize its behavior.
The function handles exceptions gracefully. If an exception occurs during the fetch orders operation, it logs the exception and continues with the next iteration.

"""
function watch_orders!(s::LiveStrategy, ai; exc_kwargs=(;))
    @debug "watch orders: get task" ai islocked(s) _module = LogTasks2
    tasks = asset_tasks(s, ai)
    @debug "watch orders: locking" ai islocked(s) _module = LogTasks2
    @lock tasks.lock begin
        @deassert tasks.byname === asset_tasks(s, ai).byname
        let task = asset_orders_task(tasks.byname)
            if istaskrunning(task)
                @debug "watch orders: task running" ai islocked(s) _module = LogTasks2
                return task
            end
        end
        # Call the top-level functions
        orders_byid, stop_delay = initialize_watch_tasks!(s, ai)
        loop_func, iswatch = define_loop_funct(s, ai; exc_kwargs)
        task = @start_task orders_byid manage_order_updates!(s, ai, orders_byid, stop_delay, loop_func, iswatch)
        stop_task = @async monitor_stop_conditions!(s, ai, task, stop_delay, tasks)

        tasks.byname[:orders_task] = task
        tasks.byname[:orders_stop_task] = stop_task
        @debug "watch orders: new task" ai islocked(s) _module = LogTasks2
        return task
    end
end

asset_orders_task(tasks) = get(tasks, :orders_task, nothing)
@doc """ Retrieves the orders task for a given asset instance.

$(TYPEDSIGNATURES)

This function retrieves the orders task for a given asset instance `ai` from the live strategy `s`. The orders task is responsible for watching and updating orders for the asset instance.

"""
asset_orders_task(s, ai) = @something asset_task(s, ai, :orders_task) watch_orders!(s, ai)
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
    waitfor = attr(s, :live_stop_timeout, Second(3))
    @timeout_start
    tasks = (asset_orders_task(s, ai), asset_orders_stop_task(s, ai))
    for task in tasks
        stop_task(task)
    end
    for task in tasks
        if !istaskdone(task)
            @async begin
                this_task = $task
                waitforcond(() -> !istaskdone(this_task), @timeout_now())
                if !istaskdone(this_task)
                    kill_task(this_task)
                end
            end
        end
    end
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
    @debug "update ord: locking state" _module = LogWatchOrder id = state.order.id islocked(ai) f = @caller 7
    @lock state.lock begin
        @debug "update ord: locked" _module = LogWatchOrder id = state.order.id islocked(ai)
        this_hash = order_update_hash(resp, eid)
        state.update_hash[] == this_hash && return nothing
        # always update hash on new data
        state.update_hash[] = this_hash
        # only emulate trade if trade watcher task
        # is not running
        if !hasmytrades(exchange(ai))
            @debug "update ord: emulate trade" _module = LogWatchOrder ai = raw(ai) side = posside(state.order) id =
                state.order.id
            @lock ai if isopen(ai, state.order)
                t = emulate_trade!(s, state.order, ai; state.average_price, resp)
                @debug "update ord: emulated trade" _module = LogWatchOrder trade = t id = state.order.id
            end
        end
        # if order is filled remove it from the task orders map.
        # Also remove it if the order is not open anymore (closed, canceled, expired, rejected...)
        order_open = _ccxtisopen(resp, eid)
        order_closed = _ccxtisclosed(resp, eid)
        order_trades = trades(state.order)
        order_filled = isorder_filled(ai, state.order)

        if order_filled || !order_open
            # Wait for trades to be processed if trades are not emulated
            @debug "update ord: finalizing" _module = LogWatchOrder id = state.order.id is_synced = isorder_synced(
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
                    @debug "update ord: waiting for trade events" _module = LogWatchOrder id = state.order.id
                    waitfortrade(s, ai, state.order; waitfor=Second(1))
                    if length(order_trades) == trades_count
                        @lock ai if isopen(ai, state.order)
                            @warn "update ord: falling back to emulation." locked = islocked(
                                ai
                            ) trades_count
                            @debug "update ord: emulating trade" _module = LogWatchOrder id = state.order.id
                            t = emulate_trade!(
                                s, state.order, ai; state.average_price, resp
                            )
                            @debug "update ord: emulation done" _module = LogWatchOrder trade = t id =
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
            @debug "update ord: de activating order" _module = LogWatchOrder id = state.order.id ai = raw(ai) order_filled
            clear_order!(s, ai, state.order)
            @ifdebug if hasorders(s, ai, state.order.id)
                @warn "update ord: order should already have been removed from local state, \
                possible emulation problem" id = state.order.id order_trades = trades(
                    state.order
                )
            end
        end
    end
    @debug "update ord: handled" _module = LogWatchOrder id = state.order.id filled = filled_amount(state.order) f = @caller 7
    asset_orders_task(s, ai).storage[:notify] |> safenotify
end

_default_ordertype(islong::Bool, bs::BySide, args...) = begin
    oside = orderside(bs)
    if islong
        MarketOrder{oside}
    else
        ShortMarketOrder{opposite(oside)}
    end
end
_default_ordertype(s, ai::MarginInstance, resp) = begin
    flag = islong(ai)
    oside = if resp_order_reduceonly(resp, exchangeid(ai))
        ifelse(flag, Sell, Buy)
    else
        ifelse(flag, Buy, Sell)
    end
    _default_ordertype(flag, oside, resp)
end
_default_ordertype(s, ai::NoMarginInstance, _) = MarketOrder{cash(ai) > ZERO ? Sell : Buy}

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
        live_cancel(s, ai; ids=(id,), confirm=false)
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
        @debug "reactivate order: " _module = LogCreateOrder id resp
        o = create_live_order(
            s,
            resp,
            ai;
            t=_default_ordertype(s, ai, resp),
            price=missing,
            amount=missing,
            synced=false,
            tag="reactivate"
        )
        if o isa Order
            state = get_order_state(active_orders(s, ai), o.id; s, ai)
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

@doc "Stores an order in the recently orders cache."
record_order_update!(s::LiveStrategy, ai, resp) =
    let lru = recent_orders(s, ai)
        @debug "record order update: " _module = LogWatchOrder lru = typeof(lru) order_update_hash(resp, exchangeid(ai))
        lru[order_update_hash(resp, exchangeid(ai))] = nothing
    end
isprocessed_order_update(s::LiveStrategy, ai, resp) = order_update_hash(resp, exchangeid(ai)) ∈ keys(recent_orders(s, ai))

@doc """Manages the lifecycle of an order event.

$(TYPEDSIGNATURES)

The function extracts an order id from the `resp` object and based on the status of the order, it either updates, re-activates, or cancels the order.
It uses a semaphore to ensure the order of events is respected.
"""
function process_order!(s, ai, orders_byid, resp, sem)
    try
        eid = exchangeid(ai)
        id = resp_order_id(resp, eid, String)
        @debug "handle ord: processing" id resp
        @lock ai begin
            if isprocessed_order(s, ai, id) ||
               isprocessed_order_update(s, ai, resp)
                return nothing
            end
            record_order_update!(s, ai, resp)
        end
        @debug "handle ord: this event" _module = LogWatchOrder id = id status = resp_order_status(resp, eid)
        if isempty(id) || resp_event_type(resp, eid) != Order
            @debug "handle ord: missing order id" _module = LogWatchOrder
            return nothing
            # NOTE: when an order request is rejected by the exchange
            # a local order is never stored
        elseif _ccxtisstatus(resp, "rejected", eid)
            @debug "handle ord: rejected order" _module = LogWatchOrder
            return nothing
        else
            # TODO: we could replace the queue with the handler_tasks vector
            # since the order is the same
            # remember events order
            n = isempty(sem.queue) ? 1 : last(sem.queue) + 1
            push!(sem.queue, n)
            try
                state = get_order_state(orders_byid, id; s, ai)
                # wait for earlier events to be processed
                while first(sem.queue) != n
                    @debug "handle ord: waiting for queue" _module = LogWatchOrder n id
                    safewait(sem.cond)
                end
                if state isa LiveOrderState
                    @debug "handle ord: updating" _module = LogWatchOrder id ai = raw(ai)
                    update_order!(s, ai, eid; resp, state)
                elseif _ccxtisopen(resp, eid)
                    @debug "handle ord: re-activating (open) order" _module = LogWatchOrder id ai = raw(ai)
                    re_activate_order!(s, ai, id; eid, resp)
                else
                    for o in values(s, ai) # ensure order is not stored locally
                        if o.id == id
                            @debug "handle ord: cancelling local order since non open remotely" _module = LogWatchOrder id ai = raw(
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
        @ifdebug LogWatchOrder isdefined(Main, :e) && (Main.e[] = e)
        @debug_backtrace LogWatchOrder
        ispyminor_error(e) || @error e
    end
end

@doc """Emulates a trade based on order and response objects.

$(TYPEDSIGNATURES)

This function checks if an order is open, validates the order details (type, symbol, id, side), and calculates the filled amount.
If the filled amount has changed, it computes the new average price and checks if it's within the limits.
It then emulates the trade and updates the order state.
"""
function emulate_trade!(s::LiveStrategy, o, ai; resp,
    average_price=nothing,
    exec=true)
    eid = exchangeid(ai)
    if !isopen(ai, o) || _ccxtisstatus(resp_order_status(resp, eid), "canceled", "rejected")
        @debug "emu trade: closed/canceled order" _module = LogCreateTrade o.id
        return nothing
    end
    if !isordertype(ai, o, resp, eid) ||
       !isordersymbol(ai, o, resp, eid) ||
       !isorderid(ai, o, resp, eid; getter=resp_order_id)
        return nothing
    end
    side = _ccxt_sidetype(resp, eid; o)
    if !isorderside(side, o)
        return nothing
    end
    is_reduce_only = o isa ReduceOnlyOrder
    new_filled = resp_order_filled(resp, eid)
    prev_filled = filled_amount(o)
    actual_amount = new_filled - prev_filled
    if !is_reduce_only && actual_amount < ai.limits.amount.min
        @debug "emu trade: fill status unchanged" _module = LogCreateTrade o.id prev_filled new_filled actual_amount
        return nothing
    end
    if isnothing(average_price)
        average_price = let ap = resp_order_average(resp, eid)
            iszero(ap) ? o.price : ap
        end |> Ref
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
                @error "emu trade: unavailable fields (average or cost)" ai ai.exchange o.id resp
                (ZERO, ZERO)
            else
                prev_cost = average_price[] * prev_filled
                net_cost = this_cost - prev_cost
                if net_cost < ai.limits.cost.min && !is_reduce_only
                    @error "emu trade: net cost below min" ai net_cost o
                    (ZERO, ZERO)
                else
                    average_price[] = (prev_cost + net_cost) / new_filled
                    (net_cost, net_cost / actual_amount)
                end
            end
        end
    end
    if !isorderprice(s, ai, actual_price, o; resp) ||
       !inlimits(actual_price, ai, :price)
        return nothing
    end
    if !is_reduce_only && (
        !inlimits(net_cost, ai, :cost) ||
        !inlimits(actual_amount, ai, :amount)
    )
        return nothing
    end

    @debug "emu trade: emulating" _module = LogCreateTrade o.id
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

function wait_for_task(s, ai; waitfor)
    local aot
    slept = 0
    timeout = Millisecond(waitfor).value
    while slept < timeout
        aot = @something asset_orders_task(s, ai) missing
        if !ismissing(aot)
            break
        end
        sleep(Millisecond(100))
        slept += 100
    end
    return (slept, aot)
end

@doc """Waits for any order event to happen on the specified asset.

$(TYPEDSIGNATURES)

This function waits for a specified amount of time or until an order event happens.
It keeps track of the number of orders and checks if any new order has been added during the wait time.
If the task is not running, it stops waiting and returns the time spent waiting.
"""
function waitfororder(s::LiveStrategy, ai; waitfor=Second(3))
    aot_slept, aot = wait_for_task(s, ai; waitfor)
    @debug "wait for order: any" _module = LogWaitOrder aot aot_slept
    ismissing(aot) && return aot_slept
    timeout = Millisecond(waitfor).value
    cond = aot.storage[:notify]
    prev_count = orderscount(s, ai)
    slept = aot_slept
    @debug "wait for order: loop" _module = LogWaitOrder ai = raw(ai) waitfor
    while slept < timeout
        if istaskrunning(aot)
            slept += waitforcond(cond, timeout - slept)
            orderscount(s, ai) != prev_count && begin
                @debug "wait for order: new event" _module = LogWaitOrder ai = raw(ai) slept
                break
            end
        else
            @debug "wait for order: orders task is not running, restarting" _module = LogWaitOrder ai = raw(ai)
            aot = watch_orders!(s, ai)
            if !istaskrunning(aot)
                @error "wait for order: failed to restart task"
                return 0
            end
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
    if @lock ai !haskey(orders_byid, o.id)
        isproc = isprocessed_order(s, ai, o.id)
        @debug "Wait for order: inactive" _module = LogWaitOrder unfilled(o) filled_amount(o) isfilled(ai, o) isproc fetch_orders(s, ai, ids=(o.id,)) @caller
        return isproc || isfilled(ai, o)
    end
    @debug "Wait for order: start" _module = LogWaitOrder id = o.id timeout = timeout
    while slept < timeout
        slept += let this_slept = waitfororder(s, ai; waitfor)
            this_slept == 0 && return false
            this_slept
        end
        if !haskey(orders_byid, o.id)
            @ifdebug if isimmediate(o) && isempty(trades(o))
                @warn "Wait for order: immediate order has no trades"
            end
            @debug "Wait for order: not tracked" _module = LogWaitOrder id = o.id
            return true
        elseif !haskey(s, ai, o)
            @debug "Wait for order: not found" _module = LogWaitOrder id = o.id
            return true
        end
        if slept > timeout
            @debug "Wait for order: timedout" _module = LogWaitOrder id = o.id timeout
            return false
        end
    end
    return false
end
