import .PaperMode: SimMode
using .Executors: filled_amount, orderscount, orders
using .Executors: isfilled as isorder_filled
using .Instances: ltxzero, gtxzero
using .SimMode: @maketrade

# TODO: `watch_orders!` and `watch_trades!` currently operate on one symbol only.
# This could be improved by batching new tasks called within a short amount time
# and use the `...ForSymbols` functions from ccxt.

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
            while istaskrunning()
                try
                    while istaskrunning()
                        updates = f(flag, coro_running)
                        stop_delay[] = Second(60)
                        if updates isa Exception
                            @ifdebug ispyminor_error(updates) ||
                                @debug "Error fetching orders (using watch: $(iswatch))" updates
                            sleep(1)
                        else
                            handle_orders!(s, ai, orders_byid, updates)
                            safenotify(cond)
                        end
                    end
                catch e
                    if e isa InterruptException
                        break
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
                if orderscount(s, ai) == 0
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
asset_orders_task(s, ai) = asset_orders_task(asset_tasks(s, ai).byname)
asset_orders_stop_task(tasks) = get(tasks, :orders_stop_task, nothing)
asset_orders_stop_task(s, ai) = asset_orders_stop_task(asset_tasks(s, ai).byname)

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

function stop_watch_orders!(s::LiveStrategy, ai)
    asset_orders_stop_task(s, ai) |> stop_task
    asset_orders_task(s, ai) |> stop_task
end

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

function update_order!(s, ai, eid; resp, state)
    @lock state.lock begin
        this_hash = order_update_hash(resp, eid)
        state.update_hash[] == this_hash && return nothing
        # always update hash on new data
        state.update_hash[] = this_hash
        # only emulate trade if trade watcher task
        # is not running
        if hasmytrades(exchange(ai))
        else
            @debug "update ord: locking ai" ai = raw(ai) side = posside(state.order)
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
            delete!(active_orders(s, ai), state.order.id)
            @ifdebug if hasorders(s, ai, state.order.id)
                @warn "update ord: order should already have been removed from local state, \
                possible emulation problem" id = state.order.id order_trades = trades(
                    state.order
                )
            end
        end
    end
end

function re_activate_order!(s, ai, id; eid, resp)
    function docancel()
        @error "reactivate ord: could not re-create order, cancelling from exchange" id exc = nameof(
            exchange(ai)
        )
        live_cancel(s, ai; ids=(id,), confirm=false, all=false)
    end

    new_order = true
    # This should practically never happen
    for o in values(s, ai)
        if o.id == id
            state = set_active_order!(s, ai, o)
            @warn "reactivate ord: re-activation done" id exc = nameof(exchange(ai))
            if state isa LiveOrderState
                update_order!(s, ai, eid; resp, state)
            else
                docancel()
            end
            new_order = false
            break
        end
    end
    if new_order
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
                docancel()
            end
        else
            docancel()
        end
    end
end

_pyvalue_info(v) =
    try
        length(v)
    catch
        typeof(v)
    end
function handle_orders!(s, ai, orders_byid, order_updates)
    try
        @debug "handle ord: new events" n_updates = _pyvalue_info(order_updates)
        sem = @lget! task_local_storage() :sem (cond=Threads.Condition(), queue=Int[])
        if length(sem.queue) > 0
            @warn "handle ord: expected queue (orders) to be empty." length(sem.queue)
            empty!(sem.queue)
        end
        eid = exchangeid(ai)
        @sync for resp in order_updates
            try
                id = resp_order_id(resp, eid, String)
                @debug "handle ord: this event" id = id status = resp_order_status(resp, eid)
                if isempty(id)
                    @warn "handle ord: missing order id"
                    continue
                else
                    # remember events order
                    n = isempty(sem.queue) ? 1 : last(sem.queue) + 1
                    push!(sem.queue, n)
                    @async try
                        state = get_order_state(orders_byid, id)
                        # wait for earlier events to be processed
                        while first(sem.queue) != n
                            @debug "handle ord: waiting for queue" n
                            safewait(sem.cond)
                        end
                        if state isa LiveOrderState
                            @debug "handle ord: updating" id ai = raw(ai)
                            update_order!(s, ai, eid; resp, state)
                        elseif _ccxtisopen(resp, eid)
                            @debug "handle ord: re-activating (open) order" id ai = raw(ai)
                            re_activate_order!(s, ai, id; eid, resp)
                        else
                            @debug "handle ord: cancelling local order since non open remotely" id ai = raw(ai) s = nameof(s)
                            for o in values(s, ai) # ensure order is not stored locally
                                if o.id == id
                                    @debug "handle ord: cancelling..."
                                    cancel!(
                                        s,
                                        o,
                                        ai;
                                        err=OrderFailed(
                                            "Dangling order $id found in local state ($(raw(ai))).",
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
            catch
                @debug_backtrace
            end
        end
    catch e
        @ifdebug isdefined(Main, :e) && (Main.e[] = e)
        @debug_backtrace
        ispyminor_error(e) || @error e
    end
end

# EXPERIMENTAL
function emulate_trade!(s::LiveStrategy, o, ai; resp, average_price=Ref(o.price), exec=true)
    isopen(ai, o) || begin
        @error "Tried to execute a trade over a closed order ($(o.id))"
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
        @debug "Order fill status is not changed" o.id prev_filled new_filled actual_amount
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
                @error "Cannot emulate trade $(raw(ai)) because exchange ($(nameof(exchange(ai)))) doesn't provide either `average` or `cost` order fields."
                (ZERO, ZERO)
            else
                prev_cost = average_price[] * prev_filled
                net_cost = this_cost - prev_cost
                if net_cost < ai.limits.cost.min
                    @error "Cannot emulate trade ($(raw(ai))) because cost of new trade ($(net_cost)) would be below minimum."
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

    @debug "Emulating trade" id = o.id
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
