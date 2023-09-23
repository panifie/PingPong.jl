using PaperMode.OrderTypes
using PaperMode: reset_logs, SimMode
using .SimMode: _simmode_defaults!
using .Lang: @lget!
using .Python: @pystr, @pyconst, Py, PyList, @py, pylist, pytuple, pyne
using .TimeTicks: dtstamp
using .Misc: LittleDict
import .Instances: timestamp

struct TaskFlag
    f::Function
end
TaskFlag() =
    let sto = task_local_storage()
        TaskFlag(() -> sto[:running])
    end
# The task flag is passed to `pyfetch/pytask` as a tuple
pycoro_running(flag) = (flag,)
pycoro_running() = pycoro_running(TaskFlag())
Base.getindex(t::TaskFlag) = t.f()
istaskrunning(t) = !isnothing(t) && istaskstarted(t) && !istaskdone(t)
stop_task(t::Task) =
    if istaskrunning(t)
        try
            t.storage[:running] = false
            let cond = get(t.storage, :notify, nothing)
                isnothing(cond) || safenotify(cond)
            end
            istaskdone(t)
        catch
            @error "Running flag not set on task $t"
            false
        end
    else
        true
    end

start_task(t::Task, state) = (init_task(t, state); schedule(t); t)

init_task(t::Task, state) = begin
    if isnothing(t.storage)
        sto = t.storage = IdDict{Any,Any}()
    end
    @lget! sto :running true
    @lget! sto :state state
    @lget! sto :notify Base.Threads.Condition()
    t
end
init_task(state) = init_task(current_task, state)

istaskrunning() = task_local_storage(:running)

function stop_asset_tasks(s::LiveStrategy, ai; reset=false)
    tasks = asset_tasks(s, ai)
    for task in values(tasks.byname)
        stop_task(task)
    end
    for task in values(tasks.byorder)
        stop_task(task)
    end
    if reset
        foreach(wait, values(tasks.byname))
        foreach(wait, values(tasks.byorder))
        empty!(tasks.byname)
        empty!(tasks.byorder)
        iszero(tasks.queue[]) || begin
            @warn "Expected asset queue to be zero, found $(tasks.queue[]) (resetting)"
            tasks.queue[] = 0
        end
    end
end

function stop_all_asset_tasks(s::LiveStrategy; reset=false, kwargs...)
    if reset
        @sync for ai in s.universe
            @async stop_asset_tasks(s, ai; reset, kwargs...)
        end
    else
        for ai in s.universe
            stop_asset_tasks(s, ai; kwargs...)
        end
    end
end

function stop_strategy_tasks(s::LiveStrategy, account; reset=false)
    tasks = strategy_tasks(s, account)
    for task in values(tasks)
        stop_task(task)
    end
    if reset
        foreach(wait, values(tasks))
        empty!(tasks)
    end
end

function stop_all_strategy_tasks(s::LiveStrategy; reset=false, kwargs...)
    accounts = strategy_tasks(s)
    if reset
        @sync for acc in keys(accounts)
            @async stop_strategy_tasks(s, acc; reset, kwargs...)
        end
    else
        for acc in keys(accounts)
            stop_strategy_tasks(s, acc; kwargs...)
        end
    end
    empty!(accounts)
end

stop_all_tasks(s::LiveStrategy; reset=true) = @sync begin
    @async stop_all_asset_tasks(s; reset)
    @async stop_all_strategy_tasks(s; reset)
end

# wait_update(task::Task) = safewait(task.storage[:notify])
# update!(t::Task, k, v) =
#     let sto = t.storage
#         sto[:state][k] = v
#         safenotify(sto[:notify])
#         v
#     end

macro start_task(state, code)
    expr = quote
        let t = @task $code
            start_task(t, $state)
        end
    end
    esc(expr)
end

# const AssetOrder = Tuple{Order,AssetInstance}
const TasksDict = LittleDict{Symbol,Task}
const OrderTasksDict = Dict{Order,Task}
const AssetTasks = NamedTuple{
    (:lock, :queue, :byname, :byorder),
    Tuple{ReentrantLock,Ref{Int},TasksDict,OrderTasksDict},
}
const StrategyTasks = NamedTuple{
    (:lock, :queue, :tasks),Tuple{ReentrantLock,Ref{Int},TasksDict}
}
order_tasks(s::Strategy, ai) = asset_tasks(s, ai).byorder
asset_queue(s::Strategy, ai) = asset_tasks(s, ai).queue
function asset_tasks(s::Strategy)
    @lock s @lget! attrs(s) :live_asset_tasks finalizer(
        (_) -> stop_all_asset_tasks(s), Dict{AssetInstance,AssetTasks}()
    )
end
function asset_tasks(s::Strategy, ai)
    tasks = asset_tasks(s)
    @lock s @lget! tasks ai (;
        lock=ReentrantLock(), queue=Ref(0), byname=TasksDict(), byorder=OrderTasksDict()
    )
end
function strategy_tasks(s::Strategy)
    @lock s @lget! attrs(s) :live_strategy_tasks finalizer(
        (_) -> stop_all_strategy_tasks(s), Dict{String,TasksDict}()
    )
end
function strategy_tasks(s::Strategy, account)
    tasks = strategy_tasks(s)
    @lock s @lget! tasks account (; lock=ReentrantLock(), queue=Ref(0), tasks=TasksDict())
end
function OrderTypes.ordersdefault!(s::Strategy{Live})
    let a = attrs(s)
        _simmode_defaults!(s, a)
        reset_logs(s)
        get!(a, :throttle, Second(5))
        asset_tasks(s)
        strategy_tasks(s)
    end
    exc_live_funcs!(s)
end

_pyfilter!(out, pred::Function) = begin
    n = 0
    while n < length(out)
        o = out[n]
        if pred(o)
            out.pop(n)
        else
            n += 1
        end
    end
    out
end

function _fetch_orders(ai, fetch_func; side=Both, ids=(), kwargs...)
    symbol = raw(ai)
    eid = exchangeid(ai)
    resp = _execfunc(fetch_func; symbol, kwargs...)
    notside = let sides = if side === Both # NOTE: strict equality
            (_ccxtorderside(Buy), _ccxtorderside(Sell))
        else
            (_ccxtorderside(side),)
        end |> pytuple
        (o) -> let s = resp_order_side(o, eid)
            @py s ∉ sides
        end
    end
    should_skip = if isempty(ids)
        if side === Both
            Returns(false)
        else
            notside
        end
    else
        let ids_set = Set(ids)
            (o) -> (resp_order_id(o, eid, String) ∉ ids_set || notside(o))
        end
    end
    if resp isa PyException
        @error "Error when fetching orders for $(raw(ai)) $resp"
        return nothing
    end
    _pyfilter!(resp, should_skip)
end

function _orders_func!(a, exc)
    a[:live_orders_func] = if has(exc, :fetchOrders)
        (ai; kwargs...) ->
            _fetch_orders(ai, first(exc, :fetchOrdersWs, :fetchOrders); kwargs...)
    elseif has(exc, :fetchOrder)
        (ai; ids, kwargs...) -> let out = pylist()
            @sync for id in ids
                @async out.append(
                    _execfunc(first(exc, :fetchOrderWs, :fetchOrder), ai, id; kwargs...),
                )
            end
            out
        end
    end
end

function _open_orders_func!(a, exc; open=true)
    oc = open ? "open" : "closed"
    cap = open ? "Open" : "Closed"
    func_sym = Symbol("fetch$(cap)Orders")
    func_sym_ws = Symbol("fetch$(cap)OrdersWs")
    a[Symbol("live_$(oc)_orders_func")] = if has(exc, func_sym)
        let f = first(exc, func_sym_ws, func_sym)
            (ai; kwargs...) -> _fetch_orders(ai, f; kwargs...)
        end
    else
        fetch_func = get(a, :live_orders_func, nothing)
        @assert !isnothing(fetch_func) "`live_orders_func` must be set before `live_$(oc)_orders_func`"
        eid = typeof(exchangeid(exc))
        pred_func = o -> pyeq(Bool, resp_order_status(o, eid), @pyconst("open"))
        status_pred_func = open ? pred_func : !pred_func
        (ai; kwargs...) -> let out = pylist()
            all_orders = fetch_func(ai; kwargs...)
            for o in all_orders
                status_pred_func(o) && out.append(o)
            end
            out
        end
    end
end

_syms(ais) = ((raw(ai) for ai in ais)...,)
function _filter_positions(out, eid::EIDType, side=Hedged())
    if (@something side Hedged) == Hedged
        out
    elseif isshort(side) || islong(side)
        _pyfilter!(out, (p) -> !isside(posside_fromccxt(p, eid), side))
    end
end

function _positions_func!(a, exc)
    eid = typeof(exc.id)
    a[:live_positions_func] = if has(exc, :fetchPositions)
        (ais; side=Hedged(), kwargs...) -> let out = positions_func(exc, ais; kwargs...)
            _filter_positions(out, eid, side)
        end
    else
        f = exc.fetchPosition
        (ais; side=Hedged(), kwargs...) -> let out = pylist()
            @sync for ai in ais
                @async out.append(pyfetch(f, raw(ai); kwargs...))
            end
            _filter_positions(out, eid, side)
        end
    end
end

_execfunc(f::Py, args...; kwargs...) = @mock pyfetch(f, args...; kwargs...)
_execfunc(f::Function, args...; kwargs...) = @mock f(args...; kwargs...)

function _cancel_all_orders(ai, orders_f, cancel_f)
    sym = raw(ai)
    eid = exchangeid(ai)
    all_orders = _execfunc(orders_f, ai)
    _pyfilter!(all_orders, o -> pyne(Bool, resp_order_status(o, eid), @pyconst("open")))
    if !isempty(all_orders)
        ids = ((resp_order_id(o, eid) for o in all_orders)...,)
        _execfunc(cancel_f, ids; symbol=sym)
    end
end
function _cancel_all_orders_single(ai, orders_f, cancel_f)
    _cancel_all_orders(
        ai, orders_f, ((ids; symbol) -> begin
            @sync for id in ids
                @async _execfunc(cancel_f, id; symbol)
            end
        end)
    )
end

function _cancel_all_orders_func!(a, exc)
    a[:live_cancel_all_func] = if has(exc, :cancelAllOrders)
        func = first(exc, :cancelAllOrdersWs, :cancelAllOrders)
        (ai) -> _execfunc(func, raw(ai))
    else
        let fetch_func = get(a, :live_orders_func, nothing)
            @assert !isnothing(fetch_func) "Exchange $(nameof(exc)) doesn't support fetchOrders."
            if has(exc, :cancelOrders)
                cancel_func = first(exc, :cancelOrdersWs, :cancelOrders)
                (ai) -> _cancel_all_orders(ai, fetch_func, cancel_func)
            elseif has(exc, :cancelOrder)
                cancel_func = first(exc, :cancelOrderWs, :cancelOrder)
                (ai) -> _cancel_all_orders_single(ai, fetch_func, cancel_func)
            else
                error("Exchange $(nameof(exc)) doesn't have a method to cancel orders.")
            end
        end
    end
end

function _cancel_orders(ai, side, ids, orders_f, cancel_f)
    sym = raw(ai)
    eid = exchangeid(ai)
    all_orders = _execfunc(orders_f, ai; (isnothing(side) ? () : (; side))...)
    open_orders = (
        (
            o for o in all_orders if pyeq(Bool, resp_order_status(o, eid), @pyconst("open"))
        )...,
    )
    if !isempty(open_orders)
        if side ∈ (Buy, Sell)
            side_str = _ccxtorderside(side)
            side_ids = (
                (
                    resp_order_id(o, eid) for
                    o in open_orders if pyeq(Bool, resp_order_side(o, eid), side_str)
                )...,
            )
            _execfunc(cancel_f, side_ids; symbol=sym)
        else
            orders_ids = ((resp_order_id(o, eid) for o in open_orders)...,)
            _execfunc(cancel_f, orders_ids; symbol=sym)
        end
    end
end

function _cancel_orders_func!(a, exc)
    orders_f = a[:live_orders_func]
    a[:live_cancel_func] = if has(exc, :cancelOrders)
        cancel_f = first(exc, :cancelOrdersWs, :cancelOrders)
        (ai; side=nothing, ids=()) -> _cancel_orders(ai, side, ids, orders_f, cancel_f)
    elseif has(exc, :cancelOrder)
        cancel_f = let pyf = first(exc, :cancelOrderWs, :cancelOrder)
            (ids; symbol) -> @sync for id in ids
                @async _execfunc(pyf, id; symbol)
            end
        end
        (ai; side=nothing, ids=()) -> _cancel_orders(ai, side, ids, orders_f, cancel_f)
    else
        error("Exchange $(nameof(exc)) doesn't support any cancel order function.")
    end
end

function _create_order_func!(a, exc)
    func = first(exc, :createOrderWs, :createOrder)
    @assert !isnothing(func) "Exchange doesn't have a `create_order` function"
    a[:live_send_order_func] = (args...; kwargs...) -> _execfunc(func, args...; kwargs...)
end

function _ordertrades(resp, exc, isid=(x) -> length(x) > 0)
    (pyisnone(resp) || resp isa PyException || isempty(resp)) && return nothing
    out = pylist()
    eid = typeof(exc.id)
    append = out.append
    for o in resp
        id = resp_trade_order(o, eid)
        (pyisinstance(id, pybuiltins.str) && isid(id)) && append(o)
    end
    out
end

_skipkwargs(; kwargs...) = ((k => v for (k, v) in pairs(kwargs) if !isnothing(v))...,)

function _my_trades_func!(a, exc)
    a[:live_my_trades_func] = if has(exc, :fetchMyTrades)
        let f = first(exc, :fetchMyTradesWs, :fetchMyTrades)
            (
                (ai; since=nothing, params=nothing) -> begin
                    _execfunc(f, raw(ai); _skipkwargs(; since, params)...)
                end
            )
        end
    else
        @warn "Exchange $(nameof(exc)) does not have a method to fetch account trades (trades will be emulated)"
    end
end

_isstrequal(a::Py, b::String) = string(a) == b
_isstrequal(a::Py, b::Py) = pyeq(Bool, a, b)
_ispydict(v) = pyisinstance(v, pybuiltins.dict)
isemptish(v::Py) =
    try
        pyisnone(v) || isempty(v)
    catch
        true
    end
isemptish(v) =
    try
        isnothing(v) || isempty(v)
    catch
        true
    end

function _order_trades_func!(a, exc)
    a[:live_order_trades_func] = if has(exc, :fetchOrderTrades)
        f = first(exc, :fetchOrderTradesWs, :fetchOrderTrades)
        (ai, id; since=nothing, params=nothing) ->
            _execfunc(f; symbol=raw(ai), id, _skipkwargs(; since, params)...)
    else
        fetch_func = a[:live_my_trades_func]
        o_id_func = @something first(exc, :fetchOrderWs, :fetchOrder) Returns(())
        o_func = a[:live_orders_func]
        o_closed_func = a[:live_closed_orders_func]
        (ai, id; since=nothing, params=nothing) -> begin
            resp_latest = _execfunc(fetch_func, ai; _skipkwargs(; params)...)
            trades = _ordertrades(resp_latest, exc, ((x) -> string(x) == id))
            !isemptish(trades) && return trades
            trades = nothing
            let since = (
                    (@something since try
                        eid = exchangeid(ai)
                        ords = _execfunc(o_id_func, id, raw(ai))
                        if isemptish(ords)
                            ords = _execfunc(o_func, ai; ids=(id,))
                            if isempty(ords) # its possible for the order to not be present in
                                # the fetch orders function if it is closed
                                ords = _execfunc(o_closed_func, ai; ids=(id,))
                            end
                        end
                        if isemptish(ords)
                            @debug "Couldn't fetch order id $id ($(raw(ai))@$(nameof(exc))) (defaulting to last day orders)"
                            now() - Day(1)
                        else
                            o = if isdict(ords)
                                ords
                            elseif islist(ords)
                                ords[0]
                            else
                                @error "Unexpected returned value while fetching orders for $id \n $ords"
                                return nothing
                            end
                            trades = resp_order_trades(o, eid)
                            if isemptish(trades)
                                resp_order_timestamp(o, eid)
                            else
                                return trades
                            end
                        end
                    catch
                        @debug_backtrace
                        now() - Day(1)
                    end) - Second(1) |> dtstamp
                )
                tries = 0
                while tries < 3 && isemptish(trades)
                    resp = _execfunc(fetch_func, ai; _skipkwargs(; since, params)...)
                    trades = _ordertrades(resp, exc, ((x) -> string(x) == id))
                    since -= 86400000
                    tries += 1
                end
                return trades
            end
        end
    end
end

function _fetch_candles_func!(a, exc)
    fetch_func = first(exc, :fetcOHLCVWs, :fetchOHLCV)
    a[:live_fetch_candles_func] =
        (args...; kwargs...) -> _execfunc(fetch_func, args...; kwargs...)
end

function exc_live_funcs!(s::Strategy{Live})
    a = attrs(s)
    exc = exchange(s)
    _orders_func!(a, exc)
    _create_order_func!(a, exc)
    _positions_func!(a, exc)
    _cancel_orders_func!(a, exc)
    _cancel_all_orders_func!(a, exc)
    _open_orders_func!(a, exc; open=true)
    _open_orders_func!(a, exc; open=false)
    _my_trades_func!(a, exc)
    _order_trades_func!(a, exc)
    _fetch_candles_func!(a, exc)
end

if exc_live_funcs! ∉ st.STRATEGY_LOAD_CALLBACKS.live
    push!(st.STRATEGY_LOAD_CALLBACKS.live, exc_live_funcs!)
end

fetch_orders(s, args...; kwargs...) = attr(s, :live_orders_func)(args...; kwargs...)
function fetch_open_orders(s, args...; kwargs...)
    attr(s, :live_open_orders_func)(args...; kwargs...)
end
function fetch_closed_orders(s, args...; kwargs...)
    attr(s, :live_closed_orders_func)(args...; kwargs...)
end
function fetch_positions(s, ai::AssetInstance, args...; kwargs...)
    fetch_positions(s, (ai,), args...; kwargs...)
end
function fetch_positions(s, args...; kwargs...)
    attr(s, :live_positions_func)(args...; kwargs...)
end
cancel_orders(s, args...; kwargs...) = attr(s, :live_cancel_func)(args...; kwargs...)
function cancel_all_orders(s, args...; kwargs...)
    attr(s, :live_cancel_all_func)(args...; kwargs...)
end
function create_order(s, args...; kwargs...)
    attr(s, :live_send_order_func)(args...; kwargs...)
end
function fetch_my_trades(s, args...; kwargs...)
    attr(s, :live_my_trades_func)(args...; kwargs...)
end
function fetch_order_trades(s, args...; kwargs...)
    attr(s, :live_order_trades_func)(args...; kwargs...)
end
function fetch_candles(s, args...; kwargs...)
    attr(s, :live_fetch_candles_func)(args...; kwargs...)
end

get_positions(s) = attr(watch_positions!(s; interval=st.throttle(s)), :view)
get_positions(s, ::ByPos{Long}) = get_positions(s).long
get_positions(s, ::ByPos{Short}) = get_positions(s).short
get_positions(s, ai, bp::ByPos) = get(get_positions(s, bp), raw(ai), nothing)
function get_positions(s, ai, ::Nothing)
    get(get_positions(s, get_position_side(s, ai)), raw(ai), nothing)
end
get_positions(s, ai::AssetInstance) = get_positions(s, ai, posside(ai))
function get_position_side(s, ai::AssetInstance)
    try
        sym = raw(ai)
        long, short = get_positions(s)
        pos = get(long, sym, nothing)
        !isnothing(pos) && !pos.closed[] && return Long()
        pos = get(short, sym, nothing)
        !isnothing(pos) && !pos.closed[] && return Short()
        @something posside(ai) if hasorders(s, ai)
            @debug "No position open for $sym, inferring from open orders"
            posside(first(orders(s, ai)).second)
        elseif length(trades(ai)) > 0
            @debug "No position open for $sym, inferring from last trade"
            posside(last(trades(ai)))
        else
            @debug "No position open for $sym, defaulting to long"
            Long()
        end
    catch
        @debug_backtrace
        Long()
    end
end
_balance_bytype(::Nothing, ::Symbol) = nothing
_balance_bytype(v, sym) = getproperty(v, sym)
get_balance(s) = watch_balance!(s; interval=st.throttle(s)).view
get_balance(s, sym) =
    let bal = get_balance(s)
        isnothing(bal) && return nothing
        (; date=bal.date[], balance=get(bal.balance, sym, nothing))
    end
get_balance(s, sym, type)::Option{DFT} =
    let bal = get_balance(s)
        @ifdebug @assert type ∈ (:used, :total, :free)
        isnothing(bal) && return nothing
        _balance_bytype(get(bal.balance, sym, nothing), type)
    end
get_balance(s, ai::AssetInstance, args...) = get_balance(s, bc(ai), args...)

function timestamp(s, ai::AssetInstance; side=posside(ai))
    order_date = if hasorders(s, ai)
        v = first(keys(s, ai)).time
        @deassert v >= last(collect(keys(s, ai)))
        v
    else
        DateTime(0)
    end
    trade_date = if !isempty(trades(ai))
        last(trades(ai)).date
    else
        DateTime(0)
    end
    pos_date = if isnothing(side)
        DateTime(0)
    else
        timestamp(ai, side)
    end
    max(order_date, trade_date, pos_date)
end

function st.current_total(s::NoMarginStrategy{Live})
    bal = balance(s)
    price_func(ai) = bal[@pystr(raw(ai))] |> pytofloat
    invoke(st.current_total, Tuple{NoMarginStrategy,Function}, s, price_func)
end

macro timeout_start(start=nothing)
    esc(:(timeout_date = @something($start, now()) + waitfor))
end
macro timeout_now()
    esc(:(max(Millisecond(0), timeout_date - now())))
end
