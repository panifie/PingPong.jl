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
function watch_trades!(s::LiveStrategy, ai; exc_kwargs=(;))
    @debug "watch trades: get tasks" _module = LogTasks2 isownable(ai.lock) isownable(
        s.lock
    ) @caller(20)
    tasks = asset_tasks(ai)
    @debug "watch trades: locking" _module = LogTasks2 ai
    @lock tasks.lock begin
        @deassert tasks.byname === asset_tasks(ai).byname
        let task = asset_trades_task(tasks.byname)
            if istaskrunning(task)
                @debug "watch trades: task running" _module = LogTasks2 ai
                return task
            end
        end
        exc, stop_delay = initialize_watch_trades_tasks!(s, ai)
        if !hasmytrades(exc)
            @error "watch trades: trades monitoring is not supported" exc ai
            return nothing
        end
        loop_func, iswatch = define_trades_loop_funct(s, ai, exc; exc_kwargs)
        task = @start_task IdDict() manage_trade_updates!(
            s, ai, stop_delay, loop_func, iswatch
        )
        tasks.byname[:trades_task] = task
        @debug "watch trades: new task" _module = LogTasks2 ai task istaskstarted(task) first(
            keys(task.storage)
        )
        while !istaskstarted(task)
            sleep(0.01)
        end
        return task
    end
end

function initialize_watch_trades_tasks!(s::LiveStrategy, ai)
    exc = exchange(ai)
    stop_delay = Ref(Second(60))
    return exc, stop_delay
end

function define_trades_loop_funct(s::LiveStrategy, ai, exc; exc_kwargs=(;))
    watch_func = first(exc, :watchMyTrades)
    _, func_kwargs = splitkws(:since; kwargs=exc_kwargs)
    sym = raw(ai)
    buf_notify = @lget! ai :trades_buf_notify Condition()
    buf = @lget! ai :trades_buf Vector{Any}()
    sizehint!(buf, s[:live_buffer_size])
    if !isnothing(watch_func) && s[:is_watch_mytrades]
        init_handler() = begin
            task_local_storage(:buf_notify, buf_notify)
            task_local_storage(:buf, buf)
            # NOTE: this is NOT a Threads.Condition because we shouldn't yield inside the push function
            # (we can't lock (e.g. by using `safenotify`) must use plain `notify`)
            since = dtstamp(attr(s, :is_start, now()))
            h = @lget! task_local_storage() :handler begin
                coro_func() = watch_func(sym; since, func_kwargs...)
                errors = Ref(0)
                f_push(v) = begin
                    push!(buf, v)
                    notify(buf_notify)
                    maybe_backoff!(errors, v)
                end
                stream_handler(coro_func, f_push)
            end
            start_handler!(h)
        end
        function get_from_buffer()
            sto = task_local_storage()
            this_buf = @something get(sto, :buf, nothing) begin
                init_handler()
                sto[:buf]
            end
            notify = task_local_storage(:buf_notify)
            while isempty(this_buf)
                !@istaskrunning() && return
                wait(notify)
            end
            popfirst!(this_buf)
        end
        (get_from_buffer, true)
    else
        last_date = isempty(ai.history) ? attr(s, :is_start, now()) : last(ai.history).date
        since = Ref(last_date)
        startup = Ref(true)
        eid = exchangeid(ai)
        function flush_buf_notify()
            if !isempty(buf)
                ans = similar(buf)
                append!(ans, buf)
                empty!(buf)
                return ans
            end
        end
        function get_from_call()
            if !startup[]
                sleep(1)
            end
            updates = @something flush_buf_notify() fetch_my_trades(
                s, ai; since=dtstamp(since[]) + 1, func_kwargs...
            ) missing
            if islist(updates) && !isempty(updates)
                since[] = resp_trade_timestamp(updates[-1], eid, DateTime)
            elseif startup[]
                startup[] = false
            end
            updates
        end
        (get_from_call, false)
    end
end

function manage_trade_updates!(s::LiveStrategy, ai, stop_delay, loop_func, iswatch)
    idle_timeout = Second(s.watch_idle_timeout)
    events = get_events(ai)
    asset_cond = condition(ai)
    strategy_cond = condition(s)
    orders_byid = active_orders(ai)
    try
        while @istaskrunning()
            try
                @debug "watchers trades: loop func" _module = LogWatchTrade
                updates = loop_func()
                send_trades!(
                    s,
                    ai,
                    updates;
                    orders_byid,
                    events,
                    asset_cond,
                    strategy_cond,
                    iswatch,
                )
                stop_delay[] = idle_timeout
            catch e
                handle_trade_updates_errors!(e, ai, iswatch)
            end
        end
    finally
        h = get(task_local_storage(), :handler, nothing)
        if !isnothing(h)
            stop_handler!(h)
        end
    end
end

function send_trades!(
    s, ai, updates; orders_byid, events, asset_cond, strategy_cond, iswatch
)
    if updates isa Exception
        if updates isa InterruptException
            throw(updates)
        else
            @ifdebug ispyminor_error(updates) ||
                @debug "watch trades: fetching error" _module = LogWatchTrade ai updates
            if !iswatch
                sleep(1)
            end
        end
    elseif islist(updates)
        @debug "watch trades: resp" _module = LogWatchTrade2 updates
        for resp in pylist(updates)
            date = resp_trade_timestamp(resp, exchangeid(ai), DateTime)
            func = () -> handle_trade!(s, ai, orders_byid, resp)
            sendrequest!(ai, date, func; events)
            safenotify(asset_cond)
            safenotify(strategy_cond)
        end
    else
        date = resp_trade_timestamp(updates, exchangeid(ai), DateTime)
        func = () -> handle_trade!(s, ai, orders_byid, updates)
        sendrequest!(ai, date, func; events)
        safenotify(asset_cond)
        safenotify(strategy_cond)
    end
end

function handle_trade_updates_errors!(e, ai, iswatch)
    if e isa InterruptException || (iswatch && e isa InvalidStateException)
        rethrow(e)
    else
        @debug "watch trades: error (task termination?)" _module = LogWatchTrade raw(ai) istaskrunning() current_task().storage[:running]
        @debug_backtrace LogWatchTrade
    end
    if !iswatch
        sleep(1)
    end
end

asset_trades_task(tasks::AbstractDict) = get(tasks, :trades_task, nothing)
@doc """ Retrieves the asset trades task for a given asset instance.

$(TYPEDSIGNATURES)

This function retrieves the asset trades task for a given asset instance `ai` from the live strategy `s`. The asset trades task is responsible for watching the exchange for trades for the asset instance.

"""
function asset_trades_task(s::Strategy, ai::AssetInstance)
    @something get(asset_tasks(ai).byname, :trades_task, nothing) watch_trades!(s, ai)
end
@doc """ Checks if an exception is a specific Python exception.

$(TYPEDSIGNATURES)

This function checks if an exception `e` is a specific Python exception `pyexception`.

"""
function ispyexception(e, pyexception)
    pyisinstance(e, pyexception) || try
        hasproperty(e, :args) &&
            (length(e.args) > 0 && pyisinstance(e.args[1], pyexception))
    catch
        @debug_backtrace LogCcxtFuncs
        @ifdebug isdefined(Main, :e) && Main.e isa Ref{Any} && (Main.e[] = e)
        @error "Can't check exception of type $(typeof(e))"
        false
    end
end
function ispyminor_error(e)
    ispycanceled_error(e) || ispyinvstate_error(e)
end
function ispyinvstate_error(e)
    ispyexception(e, Python.gpa.pyaio.InvalidStateError)
end
function ispycanceled_error(e)
    ispyexception(e, Python.gpa.pyaio.CanceledError)
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
function get_order_state(orders_byid, id; s, ai, file=@__FILE__, line=@__LINE__)
    os = @something(
        get(orders_byid, id, nothing)::Union{Nothing,LiveOrderState}, findorder(s, ai; id),
    missing)
    if !(os isa LiveOrderState)
        @debug "get ord state: order not found active" _module = LogWatchOrder id _file =
            file _line = line f = @caller(10)
    end
    os
end

@doc "Stores a trade in the recently orders cache."
function record_trade_update!(s::LiveStrategy, ai, resp)
    lrt = recent_trade_update(s, ai)
    lrt[trade_hash(resp, exchangeid(ai))] = nothing
end
function delete_trade_update!(s::LiveStrategy, ai, resp)
    lrt = recent_trade_update(s, ai)
    delete!(lrt, trade_hash(resp, exchangeid(ai)))
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
function handle_trade!(s, ai, orders_byid, resp)
    try
        eid = exchangeid(ai)
        id = resp_trade_order(resp, eid, String)
        if resp_event_type(resp, eid) != ot.Trade ||
            isprocessed_order(s, ai, id) ||
            isprocessed_trade_update(s, ai, resp)
            return nothing
        end
        record_trade_update!(s, ai, resp)
        @debug "handle trade: new event" _module = LogWatchTrade order = id n_keys = length(
            resp
        )
        if isempty(id)
            @debug "handle trade: missing order id" _module = LogWatchTrade
            return nothing
        else
            try
                state = get_order_state(orders_byid, id; s, ai)
                if state isa LiveOrderState
                    @debug "handle trade: locking state" _module = LogWatchTrade id resp isownable(
                        ai.lock
                    ) isownable(state.lock)
                    @inlock ai @lock state.lock begin
                        @debug "handle trade: STATE LOCKED" _module = LogWatchTrade id resp
                        this_hash = trade_hash(resp, eid)
                        this_hash ∈ state.trade_hashes || begin
                            push!(state.trade_hashes, this_hash)
                            @debug "handle trade: exec trade" _module = LogWatchTrade ai id isownable(
                                ai.lock
                            )
                            t = begin
                                @debug "handle trade: before trade exec" _module =
                                    LogWatchTrade ai open = if ismissing(state)
                                    missing
                                else
                                    isopen(ai, state.order)
                                end state isa LiveOrderState
                                if isopen(ai, state.order)
                                    queue = asset_queue(ai)
                                    inc!(queue)
                                    try
                                        @debug "handle trade: trade!" _module =
                                            LogWatchTrade
                                        t = trade!(
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
                                            if !isnothing(t)
                                                event!(
                                                    ai,
                                                    AssetEvent,
                                                    :trade_created,
                                                    s;
                                                    trade=t,
                                                    avgp=state.average_price,
                                                )
                                            else
                                                @debug "handle trade: failed from resp" _module = LogCreateTrade ai state.order resp
                                            end
                                        t
                                    finally
                                        dec!(queue)
                                    end
                                end
                            end
                            @debug "handle trade: after exec" _module = LogWatchTrade trade =
                                t cash = cash(ai) side = if isnothing(t)
                                get_position_side(s, ai)
                            else
                                posside(t)
                            end
                        end
                    end
                else
                    reschedule() = begin
                        delete_trade_update!(s, ai, resp) # otherwise it will be skipped
                        func = () -> handle_trade!(s, ai, orders_byid, resp)
                        date = now() + Millisecond(500)
                        sendrequest!(ai, date, func)
                    end
                    # NOTE: give id directly since the _resp is for a trade and not an order
                    o = @inlock ai findorder(s, ai; resp, id)
                    if o isa Order
                        this_filled = isfilled(ai, o)
                        if this_filled && length(trades(o)) > 0
                            amount = resp_trade_amount(resp, eid)
                            last_amount = last(trades(o)).amount
                            if abs(last_amount) != amount
                                @warn "handle trade: late trade not matching last trade (wrong emu?)" ai id emulated = last_amount exchange = amount
                            end
                        elseif this_filled
                            @error "handle trade: filled order without executed trades" ai id
                        else
                            @warn "handle trade: no matching live order state (rescheduling)" ai id s resp
                            reschedule()
                        end
                    else
                        @warn "handle trade: no matching order nor state (rescheduling)" id ai resp o
                        reschedule()
                    end
                end
            finally
                asset_trades_task(s, ai).storage[:notify] |> safenotify
            end
        end
    catch e
        @ifdebug LogWatchTrade isdefined(Main, :e) && (Main.e[] = e)
        @debug_backtrace LogWatchTrade
        ispyminor_error(e) || @error e
    end
end

@doc """ Stops the watcher for trades for a specific asset instance in a live strategy.

$(TYPEDSIGNATURES)
"""
function stop_watch_trades!(s::LiveStrategy, ai)
    waitfor = attr(s, :live_stop_timeout, Second(3))
    @timeout_start
    t = asset_trades_task(s, ai)
    if istaskrunning(t)
        stop_task(t)
        if !istaskdone(t)
            sto = t.storage
            if !isnothing(sto)
                cond = get(sto, :buf_notify, nothing)
                if cond isa Condition
                    notify(cond)
                end
            end
            @async begin
                waitforcond(() -> !istaskdone(t), @timeout_now())
                if !istaskdone(t)
                    kill_task(t)
                end
            end
        end
    end
end

@doc """ Forces a fetch trades operation for a specific order in a live strategy with an asset instance.

$(TYPEDSIGNATURES)

This function forces a fetch trades operation for a specific order `o` in a live strategy `s` with an asset instance `ai`. This function is typically used when the normal fetch trades operation did not return the expected results and a forced fetch is necessary.

"""
function _force_fetchtrades(s, ai, o)
    @lock s let a = s.attrs
        _trades_resp_cache(a, ai) |> empty!
        _order_trades_resp_cache(a, ai) |> empty!
    end
    ordersby_id = active_orders(ai)
    state = get_order_state(ordersby_id, o.id; s, ai)
    @debug "force fetch trades: " _module = LogTradeFetch locked =
        state isa LiveOrderState ? isownable(state.lock) : nothing ai f = @caller(10)
    function handler()
        @debug "force fetch trades: fetching" _module = LogTradeFetch o.id
        trades_resp = fetch_order_trades(s, ai, o.id)
        if trades_resp isa Exception
            @ifdebug ispyminor_error(trades_resp) ||
                @debug "force fetch trades: error fetching trades" _module =
                LogTradeFetch trades_resp
        elseif islist(trades_resp) || trades_resp isa Vector
            @debug "force fetch trades: trades task" _module = LogTradeFetch length(trades_resp)
            task = watch_trades!(s, ai)
            waitforcond(() -> haskey(task.storage, :buf), Second(1))
            buf = task.storage[:buf]
            append!(buf, trades_resp)
            notify(task.storage[:buf_notify])
        else
            @error "force fetch trades: invalid response " trades_resp
        end
    end

    if state isa LiveOrderState
        prev_count = length(trades(o))
        waslocked = islocked(state.lock)
        @debug "force fetch trades: locking state" _module = LogTradeFetch id = o.id waslocked isownable(
            state.lock
        ) f = @caller(10)
        @lock state.lock if waslocked && length(trades(o)) != prev_count
            @debug "force fetch trades: skipping after lock" _module = LogTradeFetch
            return nothing
        else
            # NOTE: only lock asset *after* state.lock not avoid deadlocks
            handler()
        end
    else
        handler()
    end
end
