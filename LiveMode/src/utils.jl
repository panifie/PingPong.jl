using PaperMode.OrderTypes
using PaperMode: reset_logs, SimMode
using .SimMode: _simmode_defaults!
using .Lang: @lget!
using .Python: @pystr, @pyconst, Py, PyList, @py, pylist, pytuple, pyne
using .TimeTicks: dtstamp
using .Misc: LittleDict
import .Instances: timestamp

## TASKS

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

function stop_all_tasks(s::LiveStrategy; reset=true)
    @sync begin
        @async stop_all_asset_tasks(s; reset)
        @async stop_all_strategy_tasks(s; reset)
    end
    @debug "tasks: stopped all" s = nameof(s)
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
task_sem(task) = @lget! task.storage :sem (cond=Threads.Condition(), queue=Int[])
task_sem() = task_sem(current_task())
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

## WRAPPERS

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
function fetch_l2ob(s, args...; kwargs...)
    attr(s, :live_fetch_l2ob_func)(args...; kwargs...)
end

function OrderTypes.ordersdefault!(s::Strategy{Live})
    a = attrs(s)
    _simmode_defaults!(s, a)
    reset_logs(s)
    get!(a, :throttle, Second(5))
    asset_tasks(s)
    strategy_tasks(s)
    exc_live_funcs!(s)
    limit = get!(a, :sync_history_limit, 100)
    if limit > 0
        live_sync_closed_orders!(s; limit)
    end
    live_sync_strategy!(s)
end

function exc_live_funcs!(s::Strategy{Live})
    a = attrs(s)
    exc = exchange(s)
    ccxt_orders_func!(a, exc)
    ccxt_create_order_func!(a, exc)
    ccxt_positions_func!(a, exc)
    ccxt_cancel_orders_func!(a, exc)
    ccxt_cancel_all_orders_func!(a, exc)
    ccxt_open_orders_func!(a, exc; open=true)
    ccxt_open_orders_func!(a, exc; open=false)
    ccxt_my_trades_func!(a, exc)
    ccxt_order_trades_func!(a, exc)
    ccxt_fetch_candles_func!(a, exc)
    ccxt_fetch_l2ob_func!(a, exc)
end

if exc_live_funcs! ∉ st.STRATEGY_LOAD_CALLBACKS.live
    push!(st.STRATEGY_LOAD_CALLBACKS.live, exc_live_funcs!)
end

# GETTERS

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
get_position_side(::NoMarginStrategy{Live}, ::AssetInstance) = Long()
zerobal() = (; total=ZERO, free=ZERO, used=ZERO)
function zerobal_tuple()
    (; date=Ref(DateTime(0)), balance=zerobal())
end
_balance_bytype(_, ::Nothing) = nothing
_balance_bytype(::Nothing, ::Symbol) = nothing
_balance_bytype(v, sym) = getproperty(v, sym)
get_balance(s) = watch_balance!(s; interval=st.throttle(s)).view
get_balance(s, sym) =
    let bal = get_balance(s)
        isnothing(bal) && return zerobal_tuple()
        (; date=bal.date[], balance=@lget!(bal.balance, sym, zerobal()))
    end
get_balance(s, sym, type)::Option{DFT} =
    let bal = get_balance(s)
        @deassert type ∈ (:used, :total, :free, nothing)
        isnothing(bal) && return zerobal_tuple()
        tup = @lget!(bal.balance, sym, zerobal()), type
        if isnothing(type)
            tup
        else
            _balance_bytype(tup, type)
        end
    end
get_balance(s, ::Nothing, ::Nothing) = get_balance(s, nothing)
get_balance(s, ai::AssetInstance, ::Nothing=nothing) = get_balance(s, bc(ai))
get_balance(s, ::Nothing, args...) = get_balance(s, nameof(s.cash), args...)

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
