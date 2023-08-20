using .PaperMode.SimMode: trade!

_still_running(t) = !isnothing(t) && istaskstarted(t) && !istaskdone(t)
function watch_trades!(s::LiveStrategy, ai; fetch_kwargs=())
    tasks = market_tasks(s, ai)
    _still_running(tradestask(tasks)) && return nothing
    exc = exchange(ai)
    interval = st.attr(s, :throttle, Second(5))
    orders_byid = active_orders(s, ai)
    task = @start_task orders_byid begin
        f = if has(exc, :watchMyTrades)
            let sym = raw(ai), func = exc.watchMyTrades
                () -> pyfetch(func, sym; coro_running=pycoro_running())
            end
        else
            fetch_my_trades(s, ai; fetch_kwargs...)
            sleep(interval)
        end
        while istaskrunning()
            try
                while istaskrunning()
                    trades = f()
                    handle_trades!(s, ai, orders_byid, trades)
                end
            catch
                @debug "trade watching for $(raw(ai)) resulted in an error (possibly a task termination through running flag)."
                sleep(1)
            end
        end
    end
    try
        market_tasks(s)[ai][:trades_task] = task
        task
    catch
        task
    end
end

tradestask(tasks) = get(tasks, :trades_task, nothing)
tradestask(s, ai) = tradestask(market_tasks(s)[ai])
function ispyexception(e, pyexception)
    pyisinstance(e, pyexception) ||
        (length(e.args) > 0 && pyisinstance(e.args[1], pyexception))
end
function ispyresult_error(e)
    ispyexception(e, Python.gpa.pyaio.InvalidStateError)
end

function handle_trades!(s, ai, orders_byid, trades)
    try
        for resp in trades
            id = get_string(resp, "order")
            if isempty(id)
                @warn "Missing order id"
                continue
            else
                o = get(orders_byid, id, nothing)
                isnothing(o) || begin
                    t = trade!(
                        s,
                        o,
                        ai;
                        resp,
                        date=nothing,
                        price=nothing,
                        actual_amount=nothing,
                        fees=nothing,
                        slippage=false,
                    )
                    t isa Trade && safenotify(task_local_storage(:notify))
                end
            end
        end

    catch e
        ispyresult_error(e) || @error e
    end
end

function stop_watch_trades!(s::LiveStrategy, ai)
    tasks = market_tasks(s)[ai]
    t = tradestask(tasks)
    if _still_running(t)
        stop_task(t)
    end
end

function waitforcond(cond, time)
    timeout = Millisecond(time).value
    waiting = Ref(true)
    slept = Ref(0)
    try
        @async begin
            while waiting[] && slept[] < timeout
                sleep(0.1)
                slept[] += 100
            end
            slept[] > timeout && safenotify(cond)
        end
        safewait(cond)
    catch
    finally
        waiting[] = false
    end
    return slept[]
end

function waitfortrade(s::LiveStrategy, ai; waitfor=Second(1))
    tt = tradestask(s, ai)
    isnothing(tt) && return 0
    cond = tt.storage[:notify]
    prev_count = length(ai.history)
    slept = 0
    timeout = Millisecond(waitfor).value
    while slept < timeout
        slept += waitforcond(cond, waitfor)
        length(ai.history) > prev_count && return slept
    end
    return slept
end

function waitfortrade(s::LiveStrategy, ai, o::Order; waitfor=Second(1))
    order_trades = o.attrs.trades
    prev_count = length(order_trades)
    slept = 0
    timeout = Millisecond(waitfor).value
    while slept < timeout
        slept += waitfortrade(s, ai; waitfor)
        length(order_trades) > prev_count && return prev_count + 1
    end
    return prev_count
end
