using .PaperMode.SimMode: trade!
using .Lang: splitkws
using .Python: pydicthash
using LRUCache

@doc """ Determines the date from which trades should be watched on startup.

$(TYPEDSIGNATURES)

This function determines the date from which trades should be watched when the live strategy `s` starts up. The date is calculated as the current time minus a specific `offset`.

"""
function startup_watch_since(s::LiveStrategy, offset=Millisecond(1))
    last_date = DateTime(0)
    for o in values(s)
        otrades = trades(o)
        if isempty(otrades)
            if o.date > last_date
                last_date = o.date
            end
        else
            date = last(otrades).date
            if date > last_date
                last_date = date
            end
        end
    end
    if last_date == DateTime(0)
        now()
    else
        last_date + offset
    end
end

@doc """ Determines if the exchange has the `fetchMyTrades` method. """
hasmytrades(exc) = has(exc, :fetchMyTrades, :fetchMyTradesWs, :watchMyTrades)
@doc """ Starts tasks to watch the exchange for trades for an asset instance.

$(TYPEDSIGNATURES)

This function starts tasks in a live strategy `s` that watch the exchange for trades for an asset instance `ai`. It constantly checks and updates the trades based on the latest data from the exchange.

"""
function watch_trades!(s::LiveStrategy, ai; exc_kwargs=(), force=false)
    @debug "watch trades: get tasks" _module = LogWatchTrade ai = raw(ai) islocked(s) @caller
    tasks = asset_tasks(s, ai)
    @debug "watch trades: locking" _module = LogWatchTrade ai = raw(ai)
    @lock tasks.lock begin
        @deassert tasks.byname === asset_tasks(s, ai).byname
        let task = asset_trades_task(tasks.byname)
            if istaskrunning(task)
                @debug "watch trades: task running" _module = LogWatchTrade ai = raw(ai)
                return task
            end
        end
        if force || !isrunning(s)
            @debug "watch trades: strategy stopped" _module = LogWatchTrade ai = raw(ai)
            return nothing
        end
        exc = exchange(ai)
        hasmytrades(exc) || return nothing
        orders_byid = active_orders(s, ai)
        task = @start_task orders_byid begin
            (f, iswatch) = if has(exc, :watchMyTrades)
                let sym = raw(ai), func = exc.watchMyTrades
                    (
                        (flag, coro_running) -> if flag[]
                            pyfetch(func, sym; coro_running, exc_kwargs...)
                        end,
                        true,
                    )
                end
            else
                _, other_exc_kwargs = splitkws(:since; kwargs=exc_kwargs)
                last_date = isempty(ai.history) ? now() : last(ai.history).date
                since = Ref(last_date)
                startup = Ref(true)
                eid = exchangeid(ai)
                (
                    (_, _) -> begin
                        startup[] || sleep(1)
                        updates = fetch_my_trades(
                            s, ai; since=dtstamp(since[]) + 1, other_exc_kwargs...
                        )
                        if !isnothing(updates) && islist(updates) && length(updates) > 0
                            since[] = resp_trade_timestamp(updates[-1], eid, DateTime)
                        elseif startup[]
                            startup[] = false
                        end
                        updates
                    end,
                    false,
                )
            end
            queue = tasks.queue
            flag = TaskFlag()
            cond = task_local_storage(:notify)
            coro_running = pycoro_running(flag)
            sem = @lget! task_local_storage() :sem (cond=Threads.Condition(), queue=Int[])
            handler_tasks = Task[]
            while @istaskrunning()
                try
                    while @istaskrunning()
                        updates = f(flag, coro_running)
                        if updates isa InterruptException
                            throw(updates)
                        elseif updates isa Exception
                            @ifdebug ispyminor_error(updates) ||
                                     @debug "Error fetching trades (using watch: $(iswatch))" _module = LogWatchTrade updates
                            sleep(1)
                        else
                            !islist(updates) && (updates = pylist(updates))
                            for resp in updates
                                ht = @async handle_trade!(s, ai, orders_byid, resp, sem)
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
                        @debug_backtrace _module = LogWatchTrade
                        @debug "trades watching for $(raw(ai)) resulted in an error (possibly a task termination through running flag)." _module = LogWatchTrade e
                    end
                    sleep(1)
                end
            end
        end
        try
            tasks.byname[:trades_task] = task
            task
        catch
            task
        end
    end
end

asset_trades_task(tasks) = get(tasks, :trades_task, nothing)
@doc """ Retrieves the asset trades task for a given asset instance.

$(TYPEDSIGNATURES)

This function retrieves the asset trades task for a given asset instance `ai` from the live strategy `s`. The asset trades task is responsible for watching the exchange for trades for the asset instance.

"""
asset_trades_task(s, ai) =
    @lget! asset_tasks(s, ai).byname :trades_task watch_trades!(s, ai)
@doc """ Checks if an exception is a specific Python exception.

$(TYPEDSIGNATURES)

This function checks if an exception `e` is a specific Python exception `pyexception`.

"""
function ispyexception(e, pyexception)
    pyisinstance(e, pyexception) || try
        hasproperty(e, :args) &&
            (length(e.args) > 0 && pyisinstance(e.args[1], pyexception))
    catch
        @debug_backtrace _module = LogCcxtFuncs
        @ifdebug isdefined(Main, :e) && Main.e isa Ref{Any} && (Main.e[] = e)
        @error "Can't check exception of type $(typeof(e))"
        false
    end
end
function ispyminor_error(e)
    ispycancelled_error(e) || ispyinvstate_error(e)
end
function ispyinvstate_error(e)
    ispyexception(e, Python.gpa.pyaio.InvalidStateError)
end
function ispycancelled_error(e)
    ispyexception(e, Python.gpa.pyaio.CancelledError)
end

@doc """ Generates a minimal hash for a trade response. """
_trade_kv_hash(resp, eid::EIDType) = begin
    p1 = resp_trade_price(resp, eid, Py)
    p2 = resp_trade_timestamp(resp, eid)
    p3 = resp_trade_amount(resp, eid, Py)
    p4 = resp_trade_side(resp, eid)
    p5 = resp_trade_type(resp, eid)
    p6 = resp_trade_tom(resp, eid)
    hash((p1, p2, p3, p4, p5, p6))
end

@doc """ Uses the trade id to generate a hash, otherwise uses the trade info. """
function trade_hash(resp, eid)
    id = resp_trade_id(resp, eid)
    if pyisnone(id)
        info = resp_trade_info(resp, eid)
        if pyisnone(info)
            _trade_kv_hash(resp, eid)
        else
            pydicthash(info)
        end
    else
        hash(id)
    end
end

@doc """ Retrieves the state of an order with a specific ID.

$(TYPEDSIGNATURES)

This function retrieves the state of an order with a specific `id` from a collection of orders `orders_byid`. If the state is not immediately available, the function waits for a specified duration `waitfor` before trying again.

"""
function get_order_state(orders_byid, id; waitfor=Second(5), file=@__FILE__, line=@__LINE__)
    @something(
        get(orders_byid, id, nothing)::Union{Nothing,LiveOrderState},
        begin
            @debug "get ord state: order not found active, waiting" _module = LogWatchOrder id = id waitfor =
                waitfor _file = file _line = line @caller
            waitforcond(() -> haskey(orders_byid, id), waitfor)
            get(orders_byid, id, missing)
        end
    )
end

@doc "Stores a trade in the recently orders cache."
record_trade_update!(s::LiveStrategy, ai, resp) =
    let lrt = recent_trade_update(s, ai)
        lrt[trade_hash(resp, exchangeid(ai))] = nothing
    end
function isprocessed_trade_update(s, ai, resp)
    trade_hash(resp, exchangeid(ai)) ∈ keys(recent_trade_update(s, ai))
end

@doc """ Handles a trade for a live strategy with an asset instance.

$(TYPEDSIGNATURES)

This function manages a trade for a live strategy `s` with an asset instance `ai`. It looks at the collection of orders `orders_byid` and the response `resp` from the exchange to update the state of the trade.
It first checks if the trade is already present in `orders_byid`. If it is, the function updates the existing order with the new information from `resp`. If the trade is not present in `orders_byid`, the function creates a new order and adds it to `orders_byid`.
It then checks if the trade has been completed. If it has, the function updates the state of the order in `orders_byid` to reflect this.
A semaphore `sem` is used to ensure that only one thread is updating `orders_byid` at a time, to prevent data races.

"""
function handle_trade!(s, ai, orders_byid, resp, sem)
    try
        eid = exchangeid(ai)
        id = resp_trade_order(resp, eid, String)
        isprocessed_order(s, ai, id) && return nothing
        isprocessed_trade_update(s, ai, resp) && return nothing
        record_trade_update!(s, ai, resp)
        @debug "handle trade: new event" _module = LogWatchTrade order = id n_keys = length(resp)
        if isempty(id) || resp_event_type(resp, eid) != Trade
            @debug "handle trade: missing order id" _module = LogWatchTrade
            return nothing
        else
            # remember events order
            n = isempty(sem.queue) ? 1 : last(sem.queue) + 1
            push!(sem.queue, n)
            try
                let state = get_order_state(orders_byid, id)
                    if state isa LiveOrderState
                        @debug "handle trade: locking state" _module = LogWatchTrade id resp
                        @lock state.lock begin
                            this_hash = trade_hash(resp, eid)
                            this_hash ∈ state.trade_hashes || begin
                                push!(state.trade_hashes, this_hash)
                                # wait for earlier events to be processed
                                while first(sem.queue) != n
                                    safewait(sem.cond)
                                end
                                @debug "handle trade: locking ai" _module = LogWatchTrade ai = raw(ai) id
                                t = @lock ai begin
                                    @debug "handle trade: before trade exec" _module = LogWatchTrade open =
                                        if ismissing(state)
                                            missing
                                        else
                                            isopen(ai, state.order)
                                        end state isa LiveOrderState
                                    if isopen(ai, state.order)
                                        queue = asset_queue(s, ai)
                                        inc!(queue)
                                        try
                                            @debug "handle trade: trade!" _module = LogWatchTrade
                                            trade!(
                                                s,
                                                state.order,
                                                ai;
                                                resp,
                                                date=nothing,
                                                price=nothing,
                                                actual_amount=nothing,
                                                fees=nothing,
                                                slippage=false,
                                            )
                                        finally
                                            dec!(queue)
                                        end
                                    end
                                end
                                @debug "handle trade: after exec" _module = LogWatchTrade trade = t cash = cash(ai) side = if isnothing(t)
                                    get_position_side(s, ai)
                                else
                                    posside(t)
                                end
                            end
                        end
                    else
                        # NOTE: give id directly since the _resp is for a trade and not an order
                        let o = findorder(s, ai; resp, id)
                            if o isa Order
                                if isfilled(ai, o) && length(trades(o)) > 0
                                    amount = resp_trade_amount(resp, eid)
                                    last_amount = last(trades(o)).amount
                                    @warn "handle trade: no matching active order, possibly a late trade" emulated =
                                        last_amount exchange = amount
                                else
                                    @error "handle trade: expected live order state since order was not filled" id ai = raw(
                                        ai
                                    ) s = nameof(s)
                                end
                            else
                                @warn "handle trade: no matching order nor state" id ai = raw(
                                    ai
                                ) resp_order_type(resp, eid) s = nameof(s)
                            end
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
        @debug_backtrace _module = LogWatchTrade
        ispyminor_error(e) || @error e
    end
end

@doc """ Stops the watcher for trades for a specific asset instance in a live strategy.

$(TYPEDSIGNATURES)
"""
function stop_watch_trades!(s::LiveStrategy, ai)
    t = asset_trades_task(s, ai)
    if istaskrunning(t)
        stop_task(t)
    end
end

@doc """ Waits for a condition function to return true for a specified time.

$(TYPEDSIGNATURES)

This function waits for a condition function `cond` to return true. It keeps checking the condition for a specified `time`.
"""
function waitforcond(cond::Function, time)
    timeout = Millisecond(time).value
    waiting = Ref(true)
    slept = Ref(1)
    try
        while waiting[] && slept[] < timeout
            cond() && break
            sleep(0.1)
            slept[] += 100
        end
    catch
        @debug_backtrace _module = LogWait
        slept[] = timeout
    finally
        waiting[] = false
    end
    return slept[]
end

@doc """ Waits for a certain condition for a specified time.

$(TYPEDSIGNATURES)

This function waits for a certain condition `cond` to be met within a specified `time`. The condition `cond` is a function that returns a boolean value. The function continuously checks the condition until it's true or until the specified `time` has passed.

"""
function waitforcond(cond, time)
    timeout = max(Millisecond(time).value, 100)
    waiting = Ref(true)
    slept = Ref(1)
    try
        @async begin
            while waiting[] && slept[] < timeout
                sleep(0.1)
                slept[] += 100
            end
            slept[] >= timeout && safenotify(cond)
        end
        safewait(cond)
    catch
        @debug_backtrace _module = LogWait
        slept[] = timeout
    finally
        waiting[] = false
    end
    return slept[]
end

@doc """ Waits for a trade in a live strategy with a specific asset instance.

$(TYPEDSIGNATURES)

This function waits for a trade in a live strategy `s` with a specific asset instance `ai`. It continues to wait for a specified duration `waitfor` until a trade occurs.

"""
function waitfortrade(s::LiveStrategy, ai; waitfor=Second(1))
    tt = try
        asset_trades_task(s, ai)
    catch
        @debug_backtrace _module = LogWaitTrade
        return 0
    end
    if !(tt isa Task)
        @error "wait for trade: task not running (strategy stopped?)"
        return 0
    end
    timeout = Millisecond(waitfor).value
    cond = tt.storage[:notify]
    prev_count = length(ai.history)
    slept = 0
    while slept < timeout
        if istaskrunning(tt)
            slept += waitforcond(cond, timeout - slept)
            length(ai.history) != prev_count && break
        else
            break
        end
    end
    slept
end

@doc """ Waits for a specific order to trade in a live strategy with a specific asset instance.

$(TYPEDSIGNATURES)

This function waits for a specific order `o` to trade in a live strategy `s` with a specific asset instance `ai`. It continues to wait for a specified duration `waitfor` until the order is traded.

"""
function waitfortrade(s::LiveStrategy, ai, o::Order; waitfor=Second(5), force=true)
    isfilled(ai, o) && return true
    order_trades = trades(o)
    this_count = prev_count = length(order_trades)
    timeout = Millisecond(waitfor).value
    slept = 0
    side = orderside(o)
    pt = pricetime(o)
    active = active_orders(s, ai)
    _force() =
        if force
            _force_fetchtrades(s, ai, o)
            length(order_trades) > prev_count
        else
            false
        end
    @debug "wait for trade:" _module = LogWaitTrade id = o.id timeout = timeout current_trades = this_count
    while true
        slept < timeout || begin
            @debug "wait for trade: timedout" _module = LogWaitTrade id = o.id f = @caller 7
            return _force()
        end
        isactive(s, ai, o; pt, active) || begin
            @debug "wait for trade: order not present" _module = LogWaitTrade id = o.id f = @caller
            return _force()
        end
        @debug "wait for trade: " _module = LogWaitTrade isfilled(ai, o) length(order_trades)
        slept += let time = waitfortrade(s, ai; waitfor=timeout - slept)
            iszero(time) && break
            time
        end
        this_count = length(order_trades)
        this_count > prev_count && return true
    end
    this_count > prev_count
end

@doc """ Forces a fetch trades operation for a specific order in a live strategy with an asset instance.

$(TYPEDSIGNATURES)

This function forces a fetch trades operation for a specific order `o` in a live strategy `s` with an asset instance `ai`. This function is typically used when the normal fetch trades operation did not return the expected results and a forced fetch is necessary.

"""
function _force_fetchtrades(s, ai, o)
    ordersby_id = active_orders(s, ai)
    state = get_order_state(ordersby_id, o.id; waitfor=Millisecond(0))
    @debug "force fetch trades: " _module = LogTradeFetch locked =
        state isa LiveOrderState ? islocked(state.lock) : nothing ai = raw(ai) f = @caller 10
    function handler()
        @debug "force fetch trades: fetching" _module = LogTradeFetch o.id
        trades_resp = fetch_order_trades(s, ai, o.id)
        if trades_resp isa Exception
            @ifdebug ispyminor_error(trades_resp) ||
                     @debug "force fetch trades: error fetching trades" _module = LogTradeFetch trades_resp
        elseif islist(trades_resp) || trades_resp isa Vector
            @debug "force fetch trades: trades task" _module = LogTradeFetch
            trades_task = @something asset_trades_task(s, ai) watch_trades!(s, ai)
            sem = task_sem(trades_task)
            for resp in trades_resp
                handle_trade!(s, ai, ordersby_id, resp, sem)
            end
        else
            @error "force fetch trades: invalid response " trades_resp
        end
    end

    if state isa LiveOrderState
        prev_count = length(trades(o))
        waslocked = islocked(state.lock)
        @debug "force fetch trades: locking state" _module = LogTradeFetch id = o.id waslocked f = @caller 7
        @lock state.lock if waslocked && length(trades(o)) != prev_count
            @debug "force fetch trades: skipping after lock" _module = LogTradeFetch
            return nothing
        end
        handler()
    else
        handler()
    end
end
