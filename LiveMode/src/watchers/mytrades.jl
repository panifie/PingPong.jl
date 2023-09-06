using .PaperMode.SimMode: trade!
using .Lang: splitkws
using .Python: pydicthash

hasmytrades(exc) = has(exc, :fetchMyTrades, :fetchMyTradesWs, :watchMyTrades)
_still_running(t) = !isnothing(t) && istaskstarted(t) && !istaskdone(t)
function watch_trades!(s::LiveStrategy, ai; exc_kwargs=())
    tasks = asset_tasks(s, ai).byname
    _still_running(tradestask(tasks)) && return nothing
    exc = exchange(ai)
    hasmytrades(exc) || return nothing
    orders_byid = active_orders(s, ai)
    task = @start_task orders_byid begin
        f = if has(exc, :watchMyTrades)
            let sym = raw(ai), func = exc.watchMyTrades
                (flag, coro_running) -> if flag[]
                    pyfetch(func, sym; coro_running, exc_kwargs...)
                end
            end
        else
            _, other_exc_kwargs = splitkws(:since; kwargs=exc_kwargs)
            last_date = isempty(ai.history) ? now() : last(ai.history).date
            since = Ref(last_date)
            startup = Ref(true)
            eid = exchangeid(ai)
            (_, _) -> begin
                startup[] || sleep(1)
                resp = fetch_my_trades(
                    s, ai; since=dtstamp(since[]) + 1, other_exc_kwargs...
                )
                if !isnothing(resp) && islist(resp) && length(resp) > 0
                    since[] = resp_trade_timestamp(resp[-1], eid, DateTime)
                elseif startup[]
                    startup[] = false
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
                istaskrunning() || begin
                    Base.show_backtrace(stdout, Base.catch_backtrace())
                    @debug "trades watching for $(raw(ai)) resulted in an error (possibly a task termination through running flag)."
                end
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

_trade_kv_hash(resp, eid::EIDType) = begin
    p1 = resp_trade_price(resp, eid, Py)
    p2 = resp_trade_timestamp(resp, eid)
    p3 = resp_trade_amount(resp, eid, Py)
    p4 = resp_trade_side(resp, eid)
    p5 = resp_trade_type(resp, eid)
    p6 = resp_trade_tom(resp, eid)
    hash((p1, p2, p3, p4, p5, p6))
end

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

function get_order_state(orders_byid, id; waitfor=Second(5))
    @something(
        get(orders_byid, id, nothing)::Union{Nothing,LiveOrderState},
        begin
            @debug "Order not found active, waiting" id = id waitfor = waitfor
            waitforcond(() -> haskey(orders_byid, id), waitfor)
            get(orders_byid, id, missing)
        end
    )
end

# _asnum(resp, k) =
#     let s = get_string(resp, k)
#         @something tryparse(DFT, filter(!ispunct, s)) zero(DFT)
#     end

function handle_trades!(s, ai, orders_byid, trades)
    try
        cond = task_local_storage(:notify)
        eid = exchangeid(ai)
        @sync for resp in trades
            id = resp_trade_order(resp, eid, String)
            @debug "Trades task, handling new trade" order = id
            if isempty(id)
                @warn "Missing order id"
                continue
            else
                @async let state = get_order_state(orders_byid, id)
                    if state isa LiveOrderState
                        this_hash = trade_hash(resp, eid)
                        this_hash ∈ state.trade_hashes || begin
                            push!(state.trade_hashes, this_hash)
                            @info "before locking"
                            t = lock(ai) do
                                @info "isopen" open = isopen(ai, state.order)
                                if isopen(ai, state.order)
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
                                end
                            end
                            @debug "Trades task, after local trade" trade = t
                            t isa Trade && safenotify(cond)
                        end
                    else
                        @error "(trades task) Could not retrieve live order state for $id ($(raw(ai))@$(nameof(s)))"
                    end
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

function waitforcond(cond::Function, time)
    timeout = Millisecond(time).value
    waiting = Ref(true)
    slept = Ref(0)
    try
        while waiting[] && slept[] < timeout
            cond() && break
            sleep(0.1)
            slept[] += 100
        end
    catch
        slept[] = timeout
    finally
        waiting[] = false
    end
    return slept[]
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
        slept[] = timeout
    finally
        waiting[] = false
    end
    return slept[]
end

function waitfortrade(s::LiveStrategy, ai; waitfor=Second(1))
    tt = tradestask(s, ai)
    timeout = Millisecond(waitfor).value
    cond = tt.storage[:notify]
    prev_count = length(ai.history)
    slept = 0
    while slept < timeout
        if _still_running(tt)
            slept += waitforcond(cond, waitfor)
            length(ai.history) > prev_count && return slept
        else
            return timeout
        end
    end
    return slept
end

function waitfortrade(s::LiveStrategy, ai, o::Order; waitfor=Second(1))
    isfilled(ai, o) && return length(trades(o))
    order_trades = trades(o)
    this_count = prev_count = length(order_trades)
    slept = 0
    timeout = Millisecond(waitfor).value
    @debug "Waiting for trade " id = o.id timeout = timeout current_trades = this_count
    while slept < timeout
        slept += waitfortrade(s, ai; waitfor)
        this_count = length(order_trades)
        this_count > prev_count && break
    end
    return this_count
end
