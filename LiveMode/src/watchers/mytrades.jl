using .PaperMode.SimMode: trade!
using .Lang: splitkws
using .Python: pydicthash

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

hasmytrades(exc) = has(exc, :fetchMyTrades, :fetchMyTradesWs, :watchMyTrades)
function watch_trades!(s::LiveStrategy, ai; exc_kwargs=())
    tasks = asset_tasks(s, ai).byname
    istaskrunning(asset_trades_task(tasks)) && return nothing
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
                    resp = fetch_my_trades(
                        s, ai; since=dtstamp(since[]) + 1, other_exc_kwargs...
                    )
                    if !isnothing(resp) && islist(resp) && length(resp) > 0
                        since[] = resp_trade_timestamp(resp[-1], eid, DateTime)
                    elseif startup[]
                        startup[] = false
                    end
                    resp
                end,
                false,
            )
        end
        flag = TaskFlag()
        cond = task_local_storage(:notify)
        coro_running = pycoro_running(flag)
        while istaskrunning()
            try
                while istaskrunning()
                    trades = f(flag, coro_running)
                    if trades isa Exception
                        @ifdebug ispyminor_error(trades) ||
                            @debug "Error fetching trades (using watch: $(iswatch))" trades
                        sleep(1)
                    else
                        handle_trades!(s, ai, orders_byid, trades)
                        safenotify(cond)
                    end
                end
            catch e
                if e isa InterruptException
                    break
                else
                    @debug_backtrace
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

asset_trades_task(tasks) = get(tasks, :trades_task, nothing)
asset_trades_task(s, ai) = asset_trades_task(asset_tasks(s, ai).byname)
function ispyexception(e, pyexception)
    pyisinstance(e, pyexception) || try
        hasproperty(e, :args) &&
            (length(e.args) > 0 && pyisinstance(e.args[1], pyexception))
    catch
        @debug_backtrace
        isdefined(Main, :e) && (Main.e[] = e)
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

function get_order_state(orders_byid, id; waitfor=Second(5), file=@__FILE__, line=@__LINE__)
    @something(
        get(orders_byid, id, nothing)::Union{Nothing,LiveOrderState},
        begin
            @debug "Order not found active, waiting" id = id waitfor = waitfor _file = file _line =
                line
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
        @debug "Trades task:" trades = trades
        sem = @lget! task_local_storage() :sem (cond=Threads.Condition(), queue=Int[])
        if length(sem.queue) > 0
            @warn "Expected queue (trades) to be empty."
            empty!(sem.queue)
        end
        empty!(sem.queue)
        eid = exchangeid(ai)
        @sync for (n, resp) in enumerate(trades)
            id = resp_trade_order(resp, eid, String)
            @debug "Trades event" order = id
            if isempty(id)
                @warn "Missing order id"
                continue
            else
                # remember events order
                push!(sem.queue, n)
                @async try
                    let state = get_order_state(orders_byid, id)
                        if state isa LiveOrderState
                            this_hash = trade_hash(resp, eid)
                            this_hash ∈ state.trade_hashes || begin
                                push!(state.trade_hashes, this_hash)
                                # wait for earlier events to be processed
                                while first(sem.queue) != n
                                    safewait(sem.cond)
                                end
                                @debug "Locking ai"
                                t = @lock ai begin
                                    @debug "Before trade exec" open =
                                        if ismissing(state)
                                            missing
                                        else
                                            isopen(ai, state.order)
                                        end state = typeof(state)
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
                            end
                        else
                            # NOTE: give id directly since the resp is for a trade and not an order
                            let o = findorder(s, ai; resp, id)
                                if o isa Order && isfilled(ai, o) && length(trades(o)) > 0
                                    amount = resp_trade_amount(resp, eid)
                                    last_amount = last(trades(o)).amount
                                    @warn "Trade without matching active order, possibly a late trade. emulated: $last_amount, exchange: $amount "
                                else
                                    @error "(trades task) Could not retrieve live order state for $id ($(raw(ai))@$(nameof(s)))"
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
        end

    catch e
        @ifdebug isdefined(Main, :e) && (Main.e[] = e)
        @debug_backtrace
        ispyminor_error(e) || @error e
    end
end

function stop_watch_trades!(s::LiveStrategy, ai)
    t = asset_trades_task(s, ai)
    if istaskrunning(t)
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
    tt = asset_trades_task(s, ai)
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

function waitfortrade(s::LiveStrategy, ai, o::Order; waitfor=Second(1))
    isfilled(ai, o) && return length(trades(o))
    order_trades = trades(o)
    this_count = prev_count = length(order_trades)
    timeout = Millisecond(waitfor).value
    slept = 0
    @debug "Waiting for trade " id = o.id timeout = timeout current_trades = this_count
    while slept < timeout
        slept += waitfortrade(s, ai; waitfor=timeout - slept)
        this_count = length(order_trades)
        this_count > prev_count && break
    end
    return this_count
end
