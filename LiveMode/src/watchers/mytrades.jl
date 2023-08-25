using .PaperMode.SimMode: trade!
using .Lang: splitkws
using .Python: pydicthash

hasmytrades(exc) = has(exc, :fetchMyTrades, :fetchMyTradesWs, :watchMyTrades)
_still_running(t) = !isnothing(t) && istaskstarted(t) && !istaskdone(t)
function watch_trades!(s::LiveStrategy, ai; fetch_kwargs=())
    tasks = asset_tasks(s, ai).byname
    _still_running(tradestask(tasks)) && return nothing
    exc = exchange(ai)
    hasmytrades(exc) || return nothing
    interval = st.attr(s, :throttle, Second(5))
    orders_byid = active_orders(s, ai)
    task = @start_task orders_byid begin
        f = if has(exc, :watchMyTrades)
            let sym = raw(ai), func = exc.watchMyTrades
                (flag, coro_running) -> if flag[]
                    pyfetch(func, sym; coro_running, fetch_kwargs...)
                end
            end
        else
            _, other_fetch_kwargs = splitkws(:since; kwargs=fetch_kwargs)
            since = Ref(DateTime(0))
            () -> begin
                since[] == DateTime(0) || sleep(interval)
                resp = fetch_my_trades(
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
                    trades = f(flag, coro_running)
                    handle_trades!(s, ai, orders_byid, trades)
                end
            catch
                @debug "trades watching for $(raw(ai)) resulted in an error (possibly a task termination through running flag)."
                sleep(1)
            end
        end
    end
    try
        asset_tasks(s)[ai].byname[:trades_task] = task
        task
    catch
        task
    end
end

tradestask(tasks) = get(tasks, :trades_task, nothing)
tradestask(s, ai) = tradestask(asset_tasks(s, ai).byname)
function ispyexception(e, pyexception)
    pyisinstance(e, pyexception) ||
        (length(e.args) > 0 && pyisinstance(e.args[1], pyexception))
end
function ispyresult_error(e)
    ispyexception(e, Python.gpa.pyaio.InvalidStateError)
end

_trade_kv_hash(resp) = begin
    p1 = get_py(resp, "price")
    p2 = get_py(resp, "timestamp")
    p3 = get_py(resp, "amount")
    p4 = get_py(resp, "side")
    p5 = get_py(resp, "type")
    p6 = get_py(resp, "takerOrMaker")
    hash((p1, p2, p3, p4, p5, p6))
end

function trade_hash(resp)
    id = get_py(resp, "id")
    if pyisnone(id)
        info = get_py(resp, "info")
        if pyisnone(info)
            _trade_kv_hash(resp)
        else
            pydicthash(info)
        end
    else
        hash(id)
    end
end

function handle_trades!(s, ai, orders_byid, trades)
    try
        for resp in trades
            id = get_string(resp, "order")
            if isempty(id)
                @warn "Missing order id"
                continue
            else
                (o, prev_trades_hashes) = get(orders_byid, id, (nothing, nothing))
                this_hash = trade_hash(resp)
                isnothing(o) ||
                    this_hash ∈ prev_trades_hashes ||
                    begin
                        push!(prev_trades_hashes, this_hash)
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
    t = tradestask(s, ai)
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
            slept[] >= timeout && safenotify(cond)
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
