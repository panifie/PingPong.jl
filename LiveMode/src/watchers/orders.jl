import .PaperMode: SimMode
using .Executors: filled_amount, orderscount
using .Executors: isfilled as isorder_filled
using .Instances: ltxzero, gtxzero
# using .OrderTypes: OrderFailed

function watch_orders!(s::LiveStrategy, ai; fetch_kwargs=())
    _still_running(asset_orders_task(s, ai)) && return nothing
    exc = exchange(ai)
    interval = st.attr(s, :throttle, Second(5))
    orders_byid = active_orders(s, ai)
    task = @start_task orders_byid begin
        f = if has(exc, :watchOrders)
            let sym = raw(ai), func = exc.watchOrders
                (flag, coro_running) -> if flag[]
                    pyfetch(func, sym; coro_running, fetch_kwargs...)
                end
            end
        else
            _, other_fetch_kwargs = splitkws(:since; kwargs=fetch_kwargs)
            since = Ref(now())
            since_start = since[]
            () -> begin
                since[] == since_start || sleep(interval)
                resp = fetch_orders(
                    s, ai; since=dtstamp(since[]) + 1, other_fetch_kwargs...
                )
                if !isnothing(resp) && islist(resp) && length(resp) > 0
                    since[] = @something pytodate(resp[-1]) now()
                end
                resp
            end
        end
        flag = TaskFlag()
        coro_running = pycoro_running(flag)
        while istaskrunning()
            try
                while istaskrunning()
                    orders = f(flag, coro_running)
                    handle_orders!(s, ai, orders_byid, orders)
                end
            catch
                @debug "orders watching for $(raw(ai)) resulted in an error (possibly a task termination through running flag)."
                sleep(1)
            end
        end
    end
    try
        asset_tasks(s, ai).byname[:orders_task] = task
        task
    catch
        task
    end
end

asset_orders_task(tasks) = get(tasks, :orders_task, nothing)
asset_orders_task(s, ai) = asset_orders_task(asset_tasks(s, ai).byname)

_order_kv_hash(resp) = begin
    p1 = get_py(resp, "price")
    p2 = get_py(resp, "timestamp")
    p3 = get_py(resp, "stopPrice")
    p4 = get_py(resp, "triggerPrice")
    p5 = get_py(resp, "amount")
    p6 = get_py(resp, "cost")
    p7 = get_py(resp, "average")
    p8 = get_py(resp, "filled")
    p9 = get_py(resp, "remaining")
    p10 = get_py(resp, "status")
    p10 = get_py(resp, "stopLossPrice")
    p10 = get_py(resp, "takeProfitPrice")
    p11 = get_py(resp, "lastUpdateTimeStamp")
    hash((p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11))
end

function stop_watch_orders!(s::LiveStrategy, ai)
    t = asset_orders_task(s, ai)
    if _still_running(t)
        stop_task(t)
    end
end

order_update_hash(resp) = begin
    last_update = get_py(resp, "lastUpdateTimestamp")
    if pyisnone(last_update)
        info = get_py(resp, "info")
        if pyisnone(info)
            _order_kv_hash(resp)
        else
            pydicthash(info)
        end
    else
        hash(last_update)
    end
end

_ccxtisopen(resp) = pyisTrue(get_py(resp, "status") == @pystr("open"))
_ccxtisclosed(resp) = pyisTrue(get_py(resp, "status") == @pystr("closed"))

function handle_orders!(s, ai, orders_byid, orders)
    try
        for resp in orders
            id = get_string(resp, "id")
            if isempty(id)
                @warn "Missing order id"
                continue
            else
                state = get(orders_byid, id, (nothing, nothing))
                isnothing(state.order) || begin
                    this_hash = order_update_hash(resp)
                    if state.update_hash[] != this_hash
                        # always update hash on new data
                        state.update_hash[] = this_hash
                        # only emulate trade if trade watcher task
                        # is not running
                        hasmytrades(exchange(ai)) ||
                            emulate_trade!(s, state.order, ai; state, resp)
                        # if order is filled remove it from the task orders map.
                        # Also remove it if the order is not open anymore (closed, cancelled, expired, rejected...)
                        if Executors.isfilled(ai, state.order) || !_ccxtisopen(resp)
                            # Order did not complete, send an error
                            if !_ccxtisclosed(resp)
                                cancel!(
                                    s,
                                    state.order,
                                    ai;
                                    err=OrderFailed(get_string(resp, "status")),
                                )
                            end
                            delete!(orders_byid, id)
                            # if there are no more orders, stop the monitoring task
                            if orderscount(s, ai) == 0
                                stop_watch_orders!(s, ai)
                                # also stop the trades task if running
                                if hasmytrades(exchange(ai))
                                    stop_watch_trades!(s, ai)
                                end
                            end
                        end
                        safenotify(task_local_storage(:notify))
                    end
                end
            end
        end

    catch e
        ispyresult_error(e) || @error e
    end
end

# EXPERIMENTAL
function emulate_trade!(s::LiveStrategy, o, ai; state, resp)
    isopen(ai, o) || begin
        @error "Tried to execute a trade over a closed order ($(o.id))"
        return nothing
    end
    _check_type(ai, o, resp) || return nothing
    _check_symbol(ai, o, resp) || return nothing
    _check_id(ai, o, resp; k=Trf.id) || return nothing
    side = _tradeside(resp, o)
    _check_side(side, o) || return nothing
    new_filled = get_float(resp, "filled")
    prev_filled = filled_amount(o)
    actual_amount = new_filled - prev_filled
    ltxzero(ai, actual_amount, Val(:amount)) && return nothing
    prev_cost = state.average_price[] * prev_filled
    (net_cost, actual_price) = let ap = get_float(resp, "average_price")
        if ap > zero(ap)
            net_cost = let c = get_float(resp, "cost")
                iszero(c) ? ap * actual_amount : c
            end
            this_price = (ap - prev_cost) / actual_amount
            state.average_price[] = ap
            (net_cost, this_price)
        else
            this_cost = get_float(resp, "cost")
            if iszero(this_cost)
                @error "Cannot emulate trade $(raw(ai)) because exchange ($(nameof(exchange(ai)))) doesn't provide either `average` or `cost` order fields."
                (ZERO, ZERO)
            else
                prev_cost = state.average_price[] * prev_filled
                net_cost = this_cost - prev_cost
                if net_cost < ai.limits.cost.min
                    @error "Cannot emulate trade ($(raw(ai))) because cost of new trade ($(net_cost)) would be below minimum."
                    (ZERO, ZERO)
                else
                    state.average_price[] = (prev_cost + net_cost) / new_filled
                    (net_cost, net_cost / actual_amount)
                end
            end
        end
    end
    _check_price(s, ai, actual_price) || return nothing
    check_limits(actual_price, ai, :price) || return nothing
    check_limits(net_cost, ai, :cost) || return nothing
    check_limits(actual_amount, ai, :amount) || return nothing

    _warn_cash(s, ai, o; actual_amount)
    date = @something pytodate(resp) now()
    fees_quote, fees_base = _tradefees(
        resp, orderside(o), ai; actual_amount=actual_amount, net_cost=net_cost
    )
    size = _addfees(net_cost, fees_quote, o)
    trade = @maketrade
    trade!(
        s,
        state.order,
        ai;
        resp,
        trade,
        date=nothing,
        price=nothing,
        actual_amount=nothing,
        fees=nothing,
        slippage=false,
    )
end

function waitfororder(s::LiveStrategy, ai; waitfor=Second(5))
    aot = asset_orders_task(s, ai)
    timeout = Millisecond(waitfor).value
    cond = aot.storage[:notify]
    if _still_running(aot)
        return waitforcond(cond, waitfor)
    else
        return timeout
    end
end

function waitfororder(s::LiveStrategy, ai, o::Order; waitfor=Second(5))
    slept = 0
    timeout = Millisecond(waitfor).value
    orders_byid = active_orders(s, ai)
    while slept < timeout
        slept += waitfororder(s, ai; waitfor)
        if !haskey(orders_byid, o.id)
            break
        end
    end
    return isorder_filled(ai, o)
end
