using PaperMode.OrderTypes
using PaperMode: reset_logs, SimMode
using .SimMode: _simmode_defaults!
using .Lang: @lget!, Option, @get, MatchString
using .Python: @pystr, @pyconst, Py, PyList, @py, pylist, pytuple, pyne
using .TimeTicks: dtstamp
using .Misc:
    LittleDict,
    istaskrunning,
    @istaskrunning,
    init_task,
    start_task,
    stop_task,
    TaskFlag,
    waitforcond,
    @start_task,
    task_sem
using .SimMode.Instances.Data: nrow
using Watchers: Watcher
import .Instances: timestamp

# logmodules
baremodule LogPos end
baremodule LogPosClose end
baremodule LogPosSync end
baremodule LogPosFetch end
baremodule LogPosWait end
baremodule LogUniSync end
baremodule LogCreateOrder end
baremodule LogCancelOrder end
baremodule LogSendOrder end
baremodule LogSyncOrder end
baremodule LogWaitOrder end
baremodule LogTasks end
baremodule LogCreateTrade end
baremodule LogOHLCV end
baremodule LogCcxtFuncs end
baremodule LogBalance end
baremodule LogWatchBalance end
baremodule LogWatchOrder end
baremodule LogWatchTrade end
baremodule LogWatchPos end
baremodule LogWatchPos2 end
baremodule LogWatchPosProcess end
baremodule LogWait end
baremodule LogWaitTrade end
baremodule LogTradeFetch end

## TASKS

@doc """ Stops all tasks associated with a particular asset.

$(TYPEDSIGNATURES)

This function stops all tasks associated with an asset `ai` in the strategy `s`. If the `reset` flag is set, it also clears the task queues and resets the asset's task queue length.

"""
function stop_asset_tasks(s::LiveStrategy, ai; reset=false)
    tasks = asset_tasks(s, ai)
    for (name, task) in tasks.byname
        stop_task(task)
    end
    for task in values(tasks.byorder)
        stop_task(task)
    end
    if reset
        reset_asset_tasks!(tasks)
    end
end

function reset_asset_tasks!(tasks)
    for (name, task) in tasks.byname
        if istaskrunning(task)
            @debug "waiting for asset task" _module = LogTasks name
            Base.throwto(task, InterruptException())
            wait(task)
        end
    end
    for (order, task) in tasks.byorder
        if istaskrunning(task)
            @debug "waiting for asset task" _module = LogTasks order
            Base.throwto(task, InterruptException())
            wait(task)
        end
    end
    empty!(tasks.byname)
    empty!(tasks.byorder)
    iszero(tasks.queue[]) || begin
        @warn "Expected asset queue to be zero, found $(tasks.queue[]) (resetting)"
        tasks.queue[] = 0
    end
end

@doc """ Stops all tasks associated with all assets.

$(TYPEDSIGNATURES)

This function stops all tasks associated with all assets in the strategy `s`. If the `reset` flag is set, it also clears the task queues and resets the task queue lengths for all assets.

"""
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
    @debug "strat: all asset tasks stopped" s = nameof(s)
end

@doc """ Stops all tasks associated with a strategy.

$(TYPEDSIGNATURES)

This function stops all tasks associated with a strategy `s` for a specific `account`. If the `reset` flag is set, it also clears the task queues and resets the task queue lengths for the account.

"""
function stop_strategy_tasks(s::LiveStrategy, account=current_account(s); reset=false)
    tasks = strategy_tasks(s, account)
    for task in values(tasks.tasks)
        stop_task(task)
    end
    if reset
        for (name, task) in tasks.tasks
            if istaskrunning(task)
                @debug "waiting for strategy task" _module = LogTasks account name
                wait(task)
            end
        end
        empty!(tasks.tasks)
    end
end

@doc """ Stops all tasks associated with a strategy.

$(TYPEDSIGNATURES)

This function stops all tasks associated with strategy `s`. If the `reset` flag is set, it also clears all task queues and resets all task queue lengths in the strategy.

"""
function stop_all_strategy_tasks(s::LiveStrategy; reset=false, kwargs...)
    accounts = all_strategy_tasks(s)
    if reset
        @sync for acc in keys(accounts)
            @async stop_strategy_tasks(s, acc; reset, kwargs...)
        end
    else
        for acc in keys(accounts)
            stop_strategy_tasks(s, acc; kwargs...)
        end
    end
    @debug "strat: all strategy tasks stopped" s = nameof(s)
    empty!(accounts)
end

@doc """ Stops all tasks in a strategy.

$(TYPEDSIGNATURES)

This function stops all tasks associated with strategy `s`. If the `reset` flag is set to true, it also resets all task queues and lengths, effectively stopping all asset and strategy tasks and watches.

"""
function stop_all_tasks(s::LiveStrategy; reset=true)
    # these are non blocking
    stop_watch_ohlcv!(s)
    stop_watch_positions!(s)
    stop_watch_balance!(s)
    @sync begin
        @async stop_all_asset_tasks(s; reset)
        @async stop_all_strategy_tasks(s; reset)
    end
    @debug "strategy: stopped all tasks" _module = LogTasks s = nameof(s)
end

# const AssetOrder = Tuple{Order,AssetInstance}
const TasksDict = LittleDict{Symbol,Task}
const OrderTasksDict = Dict{Order,Task}
@doc """ A dictionary of tasks associated with an `AssetInstance`.

- `byname`: tasks that are _asset wide_
- `byorder` tasks that are per order (and therefore should never outlive the order)
- `lock`: is held when starting or stopping new tasks
- `queue`: currently unused
"""
const AssetTasks = NamedTuple{
    (:lock, :queue, :byname, :byorder),
    Tuple{ReentrantLock,Ref{Int},TasksDict,OrderTasksDict},
}
@doc """ A dictionary of tasks associated with a `Strategy`.
- `tasks`: tasks that are strategy wide
- `queue`: currently unused
- `lock`: is held when starting or stopping new tasks
"""
const StrategyTasks = NamedTuple{
    (:lock, :queue, :tasks),Tuple{ReentrantLock,Ref{Int},TasksDict}
}

@doc """ Retrieves the task associated with an order. """
function order_task(s::LiveStrategy, ai, k; tasks=nothing)
    tup = asset_tasks(s, ai; tasks)
    @lock tup.lock get(tup.byorder, k, nothing)
end

@doc """ Retrieves the task queue of an asset.

$(TYPEDSIGNATURES)

This function retrieves the task queue associated with an asset `ai` in the strategy `s`.

"""
asset_queue(s::LiveStrategy, ai; tasks=nothing) =
    @something(tasks, asset_tasks(s, ai)).queue
@doc """ Retrieves tasks associated with all assets.

$(TYPEDSIGNATURES)

This function retrieves tasks associated with all assets in the strategy `s`. It returns a dictionary mapping asset identifiers to their respective tasks.

"""
function asset_tasks(s::LiveStrategy)
    @lock s @lget! attrs(s) :live_asset_tasks Dict{AssetInstance,AssetTasks}()
end
@doc """ Retrieves tasks associated with a specific asset.

$(TYPEDSIGNATURES)

This function retrieves tasks associated with a specific asset `ai` in the strategy `s`. It returns a [`AssetTasks`](@ref) representing a collection of tasks associated with the asset.

"""
function asset_tasks(s::LiveStrategy, ai; tasks=nothing)
    @lock s @lget! @something(tasks, asset_tasks(s)) ai (;
        lock=ReentrantLock(), queue=Ref(0), byname=TasksDict(), byorder=OrderTasksDict()
    )
end
function asset_task(s::LiveStrategy, ai, k; tasks=nothing)
    tup = @something tasks asset_tasks(s, ai; tasks)
    @lock tup.lock begin
        get(tup.byname, k, nothing)
    end
end

function _set_task!(s::LiveStrategy, ai, t::Task, k, tasks=nothing; kind::Symbol)
    if istaskrunning(t)
        tasks = @something tasks asset_tasks(s, ai)
        @lock tasks.lock begin
            inc!(tasks.queue)
            try
                getproperty(tasks, kind)[k] = t
            finally
                dec!(tasks.queue)
            end
        end
    else
        @debug "strat: refusing to set non running task" _module = LogTasks k
    end
end

function set_asset_task!(s::LiveStrategy, ai, t::Task, k; tasks=nothing)
    _set_task!(s, ai, t, k, tasks; kind=:byname)
end

function set_order_task!(s::LiveStrategy, ai, t::Task, k; tasks=nothing)
    _set_task!(s, ai, t, k, tasks; kind=:byorder)
end

@doc """ Retrieves tasks associated with a strategy.

$(TYPEDSIGNATURES)

This function retrieves tasks associated with the strategy `s`. It returns a dictionary mapping account identifiers to their respective [`StrategyTasks`](@ref).

"""
function all_strategy_tasks(s::LiveStrategy)
    @lock s begin
        @lget! attrs(s) :live_strategy_tasks Dict{String,StrategyTasks}()
    end
end
@doc """ Retrieves tasks associated with a strategy for a specific account.

$(TYPEDSIGNATURES)

This function retrieves tasks associated with the strategy `s` for a specific `account`. It returns the account [`StrategyTasks`](@ref].

"""
function strategy_tasks(s::LiveStrategy, account=current_account(s))
    tasks = all_strategy_tasks(s)
    @lock s @lget! tasks account (; lock=ReentrantLock(), queue=Ref(0), tasks=TasksDict())
end

function set_strategy_task!(
    s::LiveStrategy, task::Task, k::Symbol; account=current_account(s), tasks=nothing
)
    if istaskrunning(task)
        tuple = @something tasks strategy_tasks(s, account)
        tuple.queue[] += 1
        try
            @lock tuple.lock begin
                tuple.tasks[k] = task
            end
        finally
            tuple.queue[] -= 1
        end
    else
        @warn "strat: refusing to set non running task" k task istaskrunning(task) task.result
    end
end

function strategy_task(
    s::LiveStrategy, k; account=current_account(s), tasks=nothing, dolock=true
)
    tup = @something tasks strategy_tasks(s, account)
    if dolock
        @lock tup.lock get(tup.tasks, k, nothing)
    else
        get(tup.tasks, k, nothing)
    end
end

## WRAPPERS
# NOTE: ONLY use this macro on the lowest level wrapper functions
@doc """ Retries executing an expression a certain number of times.

$(TYPEDSIGNATURES)

This macro retries executing an expression `expr` for a specified number of times `count`. If `count` is not provided, it defaults to 3. This is useful in cases where an operation might fail temporarily and could succeed if retried.

"""
macro retry(expr, count=3, check=isa, value=Exception)
    ex = quote
        att = 0
        while true
            resp = $(expr)
            if $check(resp, $value)
                att += 1
                att > $(count) && return resp
            else
                return resp
            end
            sleep(att)
        end
    end
    esc(ex)
end

@doc "Filter out items from a list starting from give `idx`."
filterfrom!(pred::Function, out; idx=0) = begin
    n = idx
    while n < length(out)
        o = out[n]
        if pred(o)
            delete!(out, n)
        else
            n += 1
        end
    end
    out
end

@doc """ Retrieves orders of an asset (open and closed). """
fetch_orders(s, args...; kwargs...) = @retry s[:live_orders_func](args...; kwargs...)
@doc """ Retrieves open orders of an asset. """
function fetch_open_orders(s, ai=nothing, args...; kwargs...)
    @retry s[:live_open_orders_func](ai, args...; kwargs...)
end
@doc """ Retrieves closed orders of an asset. """
function fetch_closed_orders(s, args...; kwargs...)
    @retry s[:live_closed_orders_func](args...; kwargs...)
end
function fetch_positions(s, ai::AssetInstance, args...; kwargs...)
    fetch_positions(s, (ai,), args...; kwargs...)
end
@doc """ Retrieves positions of an asset. """
function fetch_positions(s, args...; kwargs...)
    @retry s[:live_positions_func](args...; kwargs...)
end
@doc """ Retrieves all asset positions for a strategy. """
fetch_positions(s; kwargs...) =
    fetch_positions(s, ((ai for ai in s.universe)...,); kwargs...)
@doc """ Cancels orders of an asset by order identifier. """
cancel_orders(s, args...; kwargs...) = @retry s[:live_cancel_func](args...; kwargs...)
@doc """ Cancels all orders of an asset. """
function cancel_all_orders(s, args...; kwargs...)
    @retry s[:live_cancel_all_func](args...; kwargs...)
end
@doc """ Creates an order. """
function create_order(s, args...; kwargs...)
    @retry s[:live_send_order_func](args...; kwargs...)
end
@doc """ Retrieves trades of an asset. """
function fetch_my_trades(s, args...; kwargs...)
    @retry s[:live_my_trades_func](args...; kwargs...)
end
@doc """ Retrieves order trades of an asset. """
function fetch_order_trades(s, args...; kwargs...)
    @retry s[:live_order_trades_func](args...; kwargs...)
end
@doc """ Retrieves candles of an asset. """
function fetch_candles(s, args...; kwargs...)
    @retry s[:live_fetch_candles_func](args...; kwargs...)
end
@doc """ Retrieves The orderbook L2 of an asset. """
function fetch_l2ob(s, args...; kwargs...)
    @retry s[:live_fetch_l2ob_func](args...; kwargs...)
end

@doc """ Sets default values for a live strategy.

$(TYPEDSIGNATURES)

This function sets default values for a live strategy `s`. These defaults include setting up task queues, setting up assets, setting default parameters, among others.

"""
function st.default!(s::LiveStrategy)
    a = attrs(s)
    _simmode_defaults!(s, a)
    reset_logs(s)

    throttle = get!(a, :throttle, Second(5))
    throttle_per_asset = throttle * nrow(s.universe.data)
    limit = get!(a, :sync_history_limit, 100)
    # The number of trades (lists) responses to cache
    get!(
        a,
        :trades_cache_ttl,
        round(Int, 1000 / Second(throttle).value) |> Second |> Millisecond,
    )
    # The number of days to look back for an order previous trades
    get!(a, :max_order_lookback, Day(3))
    # How long to cache orders (lists) responses for
    get!(a, :orders_cache_ttl, throttle_per_asset)
    # How long to cache open orders (lists) responses for
    get!(a, :open_orders_ttl, throttle_per_asset)
    # How long to cache closed orders (lists) responses for
    get!(a, :closed_orders_ttl, throttle_per_asset)
    # How long to cache orders (dicts) responses for
    get!(a, :order_byid_ttl, throttle_per_asset)
    # How long to cache position updates (lists)
    get!(a, :positions_ttl, Second(3))
    # How long to cache fetch all orders/trades calls
    get!(a, :func_cache_ttl, Second(3))

    asset_tasks(s)
    strategy_tasks(s)
    # functions that throw an error on first run are disabled (e.g. *Ws functions)
    a[:disabled_funcs] = Dict{Symbol,Bool}()
    set_exc_funcs!(s)
    # if `true` watchers will start even if strategy is stopped
    a[:live_force_watch] = false
    # The number of entries in watchers channels buffers
    a[:live_buffer_size] = 1000
    # Dict indicating the latest (remotely) set margin mode for an asset
    a[:live_margin_mode] = Dict{AssetInstance,Union{Missing,MarginMode}}()
    if s isa MarginStrategy
        a[:positions_base_timeout] = Ref(Second(5))
    end

    if limit > 0
        live_sync_closed_orders!(s; limit)
    end
    first_start = !haskey(a, :is_running)
    live_sync_open_orders!(s; overwrite=first_start)
end

@doc """ Creates exchange-specific closure functions for a live strategy.

$(TYPEDSIGNATURES)

This function creates exchange-specific closure functions for a live strategy `s`. These closures encapsulate the context of the strategy and the specific exchange at the time of their creation.

"""
function set_exc_funcs!(s::LiveStrategy)
    a = attrs(s)
    exc = exchange(s)
    ccxt_orders_func!(a, exc)
    ccxt_create_order_func!(a, exc)
    ccxt_positions_func!(a, exc)
    ccxt_cancel_orders_func!(a, exc)
    ccxt_cancel_all_orders_func!(a, exc)
    ccxt_oc_orders_func!(a, exc; open=true)
    ccxt_oc_orders_func!(a, exc; open=false)
    ccxt_my_trades_func!(a, exc)
    ccxt_order_trades_func!(a, exc)
    ccxt_fetch_candles_func!(a, exc)
    ccxt_fetch_l2ob_func!(a, exc)
end

if set_exc_funcs! ∉ st.STRATEGY_LOAD_CALLBACKS.live
    push!(st.STRATEGY_LOAD_CALLBACKS.live, set_exc_funcs!)
end

# GETTERS

@doc """ Retrieves positions of a strategy.

$(TYPEDSIGNATURES)

This function retrieves the positions associated with a strategy `s`. It achieves this by watching the positions with a specified interval and returning the view attribute of the positions.

"""
get_positions(s) = attr(watch_positions!(s; interval=st.throttle(s)), :view)
get_positions(s, ::ByPos{Long}) = get_positions(s).long
get_positions(s, ::ByPos{Short}) = get_positions(s).short
get_positions(s, ai, bp::ByPos) = get(get_positions(s, bp), raw(ai), nothing)
function get_positions(s, ai, side=get_position_side(s, ai))
    pside = @something posside(side) get_position_side(s, ai)
    get(get_positions(s, pside), raw(ai), nothing)
end
@doc """ Retrieves the position side of an asset instance in a strategy.

$(TYPEDSIGNATURES)

This function retrieves the position side of an asset with best effort.
"""
function get_position_side(s, ai::AssetInstance)
    try
        sym = raw(ai)
        long, short, last = get_positions(s)
        last_pos = get(last, sym, missing)
        long_pos = get(long, sym, missing)
        if islong(last_pos) && !ismissing(long_pos) && !long_pos.closed[]
            return Long()
        end
        short_pos = get(short, sym, missing)
        if isshort(last_pos) && !ismissing(short_pos) && !short_pos.closed[]
            return Short()
        end
        @something posside(ai) if hasorders(s, ai)
            @debug "No position open for $sym, inferring from open orders" _module = LogPos
            posside(first(orders(s, ai)).second)
        elseif length(trades(ai)) > 0
            @debug "No position open for $sym, inferring from last trade" _module = LogPos
            posside(last(trades(ai)))
        else
            @debug "No position open for $sym, defaulting to long" _module = LogPos
            Long()
        end
    catch
        @debug_backtrace LogPos
        Long()
    end
end
get_position_side(::NoMarginStrategy{Live}, ::AssetInstance) = Long()
@doc """ Provides a zeroed-out balance.

$(TYPEDSIGNATURES)

The zero balance for an asset instance.

"""
zerobal() = (; total=ZERO, free=ZERO, used=ZERO)
@doc """ Creates a new balance tuple.

The date represents the time the balance was fetched.
"""
function zerobal_tuple()
    (; date=Ref(DateTime(0)), balance=zerobal())
end
_balance_bytype(_, ::Nothing) = nothing
_balance_bytype(::Nothing, ::Symbol) = nothing
_balance_bytype(v, sym) = getproperty(v, sym)
@doc """ Retrieves the balance of a strategy.

$(TYPEDSIGNATURES)

This function retrieves the balance associated with a strategy `s`. It achieves this by watching the balance with a specified interval and returning the view of the balance.

"""
get_balance(s) = watch_balance!(s; interval=st.throttle(s)).view
function get_balance(s, sym; fallback_kwargs=(;), bal=get_balance(s))
    if isnothing(bal) || sym ∉ keys(bal.balance)
        if nameof(s.cash) == sym || st.inuniverse(sym, s)
            _force_fetchbal(s; fallback_kwargs)
            bal = get_balance(s)
        else
            return zerobal_tuple()
        end
    end
    (; date=bal.date[], balance=@lget!(bal.balance, sym, zerobal()))
end
get_balance(s, sym, type; kwargs...) = begin
    @deassert type ∈ (:used, :total, :free, nothing)
    tup = get_balance(s, sym; kwargs...)
    if isnothing(type)
        tup
    else
        _balance_bytype(tup, type)
    end
end
get_balance(s, ::Nothing, ::Nothing) = get_balance(s, nothing)
function get_balance(s, ai::AssetInstance, tp::Option{Symbol}=nothing; kwargs...)
    get_balance(s, bc(ai), tp; kwargs...)
end
function get_balance(s, ::Nothing, args...; kwargs...)
    get_balance(s, nameof(s.cash), args...; kwargs...)
end

@doc """ Retrieves the timestamp for a specific asset instance in a strategy.

$(TYPEDSIGNATURES)

This function retrieves the most recent timestamp associated with a specific asset instance `ai` in a strategy `s`. If the `side` argument is not provided, it defaults to the position side of the asset instance.

"""
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

@doc """ Starts a timeout.

$(TYPEDSIGNATURES)

This macro starts a timeout. If a `start` argument is provided, it sets the start time of the timeout to `start`. Otherwise, it sets the start time to the current time.

"""
macro timeout_start(start=nothing)
    esc(:(timeout_date = @something $start now() + waitfor))
end
@doc """ Retrieves the current timeout.

$(TYPEDSIGNATURES)

This macro retrieves the current time of the timeout. It's typically used to check the elapsed time since a timeout started.

"""
macro timeout_now()
    esc(:(max(Millisecond(0), timeout_date - now())))
end

@doc """ Stops a live strategy.

$(TYPEDSIGNATURES)

This function stops a live strategy `s`.

"""
function stop!(s::LiveStrategy; kwargs...)
    try
        s[:stopping] = true
        stop_all_tasks(s)
    catch
        @debug_backtrace LogTasks
    finally
        invoke(stop!, Tuple{Strategy{<:Union{Paper,Live}}}, s; kwargs...)
        s[:stopping] = false
    end
end

function _last_posside(ai)
    ai_pos = position(ai)
    if isnothing(ai_pos)
        try
            posside(last(trades(ai)))
        catch
            nothing
        end
    else
        posside(ai_pos)
    end
end

_asdate(v::DateTime) = v
_asdate(v::Ref{DateTime}) = v[]

@doc """
Determines if the Watcher `w` has received an update since `last_time`.

$(TYPEDSIGNATURES)

If it has not received an update since `last_time`, returns `false`.
Otherwise, calls `this_v_func()` and compares the result to `prev_v`
and returns `true` if the watcher has received an update since `last_time`.

"""
function _isupdated(w::Watcher, prev_v, last_time; this_v_func)

    last_v = if isempty(buffer(w))
        return false
    else
        last(buffer(w))
    end
    @debug "isupdated: " _module = LogTasks prev_v last_v
    if !isempty(last_v.value) && last_v.time > last_time
        this_v = this_v_func()
        prev_nth = isnothing(prev_v)
        this_nth = isnothing(this_v)
        return if (!this_nth && prev_nth) || (this_nth && !prev_nth)
            true
        elseif (!this_nth && !prev_nth) && _asdate(this_v.date) > _asdate(prev_v.date)
            true
        else
            updated = isnothing(prev_v) || _asdate(this_v.date) > _asdate(prev_v.date)
            if updated
                process!(w)
            end
            updated
        end
    else
        return false
    end
end

function asset_bysym(s::Strategy, sym)
    @lock s begin
        dict_bysim = @lget! attrs(s) :assets_bysym Dict{String,AssetInstance}()
        @lget! dict_bysim sym s[MatchString(sym)]
    end
end
