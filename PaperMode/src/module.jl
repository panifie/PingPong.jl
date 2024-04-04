using Fetch: Fetch, pytofloat
using SimMode
using SimMode.Executors
using Base: SimpleLogger, with_logger
using .Executors: orders, orderscount
using .Executors.OrderTypes
using .Executors.TimeTicks
using .Executors.Instances
using .Executors.Misc
using .Executors.Instruments: compactnum as cnum
using .Misc.ConcurrentCollections: ConcurrentDict
using .Misc.TimeToLive: safettl
using .Misc.Lang: @lget!, @ifdebug, @deassert, Option, @writeerror, @debug_backtrace
using .Executors.Strategies: MarginStrategy, Strategy, Strategies as st, ping!
using .Executors.Strategies
using .Instances: MarginInstance
using .Instances.Exchanges: CcxtTrade
using .Instances.Data.DataStructures: CircularBuffer
using SimMode: AnyMarketOrder, AnyLimitOrder
import .Executors: pong!
import .Misc: start!, stop!, isrunning, sleep_pad

@doc "A constant `TradesCache` that is a dictionary mapping `AssetInstance` to a circular buffer of `CcxtTrade`."
const TradesCache = Dict{AssetInstance,CircularBuffer{CcxtTrade}}()

_maintf(s) = string(s.timeframe)
_opttf(s) = string(attr(s, :timeframe, nothing))
_timeframes(s) = join(string.(s.config.timeframes), " ")
_cash_total(s) = cnum(st.current_total(s, lastprice; local_bal=true))
_assets(s) =
    let str = join(getproperty.(st.assets(s), :raw), ", ")
        str[begin:min(length(str), displaysize()[2] - 1)]
    end

@doc """
Generates a formatted string representing the configuration of a given strategy.

$(TYPEDSIGNATURES)

The function takes a strategy and a throttle as input and returns a string detailing the strategy's configuration including its name, mode, throttle, timeframes, cash, assets, and margin mode.
"""
function header(s::Strategy, throttle)
    """Starting strategy $(nameof(s)) in $(nameof(typeof(execmode(s)))) mode!

        throttle: $throttle
        timeframes: $(_maintf(s)) (main), $(_maintf(s)) (optional), $(_timeframes(s)...) (extras)
        cash: $(cash(s)) [$(_cash_total(s))]
        assets: $(_assets(s))
        margin: $(marginmode(s))
        """
end
@doc """
Logs the current state of a given strategy.

$(TYPEDSIGNATURES)

The function takes a strategy as input and logs the current state of the strategy including the number of long, short, and liquidation trades, the cash committed, the total balance, and the number of increase and reduce orders.
"""
function log(s::Strategy)
    long, short, liq = st.trades_count(s, Val(:positions))
    cv = s.cash
    comm = s.cash_committed
    inc = orderscount(s, Val(:increase))
    red = orderscount(s, Val(:reduce))
    tot = st.current_total(s; price_func=lastprice, local_bal=true)
    @info string(nameof(s), "@", nameof(exchange(s))) time = now() cash = cv committed =
        comm balance = tot inc_orders = inc red_orders = red long_trades = long short_trades =
        short liquidations = liq
end

@doc """
Creates a function to flush the log and a lock for thread safety.

$(TYPEDSIGNATURES)

This function creates a `maybeflush` function that flushes the log if the time since the last flush exceeds the `log_flush_interval`. It also creates a `ReentrantLock` to ensure thread safety when flushing the log.
"""
function flushlog_func(s::Strategy)
    last_flush = Ref(DateTime(0))
    log_flush_interval = attr(s, :log_flush_interval, Second(1))
    log_lock = ReentrantLock()
    maybeflush(loghandle) =
        let this_time = now()
            if this_time - last_flush[] > log_flush_interval
                lock(log_lock) do
                    flush(loghandle)
                    last_flush[] = this_time
                end
            end
        end
    maybeflush, log_lock
end

@doc """
Executes the main loop of the strategy.

$(TYPEDSIGNATURES)

This function executes the main loop of the strategy, logging the state, flushing the log, pinging the strategy, and sleeping for the throttle duration. It handles exceptions and ensures the strategy stops running when an interrupt exception is thrown.
"""
function _doping(s; throttle, loghandle, flushlog, log_lock)
    is_running = attr(s, :is_running)
    @assert isassigned(is_running)
    setattr!(s, now(), :is_start)
    setattr!(s, missing, :is_stop)
    log_tasks = Task[]
    ping_start = DateTime(0)
    prev_cash = s.cash.value
    s_cash = s.cash
    try
        while is_running[]
            try
                if s_cash != prev_cash
                    log(s)
                    prev_cash = s_cash.value
                end
                flushlog(loghandle)
                ping_start = now()
                ping!(s, now(), nothing)
                sleep_pad(ping_start, throttle)
            catch e
                e isa InterruptException && begin
                    is_running[] = false
                    rethrow(e)
                end
                filter!(istaskdone, log_tasks)
                let lt = @async @lock log_lock try
                        @writeerror loghandle
                    catch
                        @debug "Failed to log $(now())"
                        @debug_backtrace
                    end
                    push!(log_tasks, lt)
                end
                sleep_pad(ping_start, throttle)
            end
        end
    catch e
        e isa InterruptException && rethrow(e)
        @error e
    finally
        is_running[] = false
        setattr!(s, now(), :is_stop)
        for t in log_tasks
            istaskdone(t) || schedule(t, InterruptException(); error=true)
        end
    end
end

@doc """
Starts the execution of a given strategy.

$(TYPEDSIGNATURES)

This function starts the execution of a strategy in either foreground or background mode. It sets up the necessary attributes, logs, and tasks for the strategy execution. If the strategy is already running, it throws an error.
"""
function start!(
    s::Strategy{<:Union{Paper,Live}}; throttle=throttle(s), doreset=false, foreground=false
)
    local startinfo, flushlog, log_lock
    s[:stopped] = false
    @debug "start: locking"
    @lock s begin
        attrs = s.attrs
        first_start = !haskey(attrs, :is_running)
        # HACK: `default!` locks the strategy during syncing, so we unlock here to avoid deadlocks.
        # This should not be required since the lock is reentrant.
        # Does syncing use multiple threads? It should not..
        unlock(s)
        try
            if doreset
                reset!(s)
            elseif first_start
                # only set defaults on first run
                default!(s)
            end
        finally
            lock(s)
        end

        if first_start
            @debug "start: first start"
            s[:is_running] = Ref(true)
        elseif s[:is_running][]
            @error "start: strategy already running" s = nameof(s)
            t = attr(s, :run_task, nothing)
            if t isa Task && istaskstarted(t) && !istaskdone(t)
            else
                @error "start: strategy running but task is not found (or not running)" s = nameof(
                    s
                )
            end
            return t
        else
            s[:is_running][] = true
        end
        @deassert attr(s, :is_running)[]

        startinfo = header(s, throttle)
        flushlog, log_lock = flushlog_func(s)
    end
    if foreground
        s[:run_task] = nothing
        @info startinfo
        _doping(s; throttle, loghandle=stdout, flushlog, log_lock)
    else
        s[:run_task] = @async begin
            logfile = runlog(s)
            loghandle = open(logfile, "w")
            try
                logger = SimpleLogger(loghandle)
                with_logger(logger) do
                    @info startinfo
                    _doping(s; throttle, loghandle, flushlog, log_lock)
                end
            finally
                flush(loghandle)
                close(loghandle)
                @assert !isopen(loghandle)
            end
        end
    end
end

@doc """
Calculates the elapsed time since the strategy started running.

$(TYPEDSIGNATURES)

This function calculates the time elapsed since the strategy started running. If the strategy has not started yet, it returns 0 milliseconds.
"""
function elapsed(s::Strategy{<:Union{Paper,Live}})
    attrs = s.attrs
    max(
        Millisecond(0),
        @coalesce(get(attrs, :is_stop, missing), now()) -
        @coalesce(get(attrs, :is_start, missing), now()),
    ) |> compact
end

@doc """
Stops the execution of a given strategy.

$(TYPEDSIGNATURES)

This function stops the execution of a strategy and logs the mode and elapsed time since the strategy started. If the strategy is running in the background, it waits for the task to finish.
"""
function stop!(s::Strategy{<:Union{Paper,Live}})
    s[:stopped] = true
    @debug "stop: locking"
    @lock s begin
        running = attr(s, :is_running, missing)
        task = attr(s, :run_task, missing)
        if running isa Ref{Bool}
            running[] = false
        end
        if task isa Task
            waitforcond(task.donenotify, throttle(s))
            if !istaskdone(task)
                @warn "strategy: hanging task, killing"
                Threads.@spawn kill_task(task)
            end
        end
    end
    @info "strategy: stopped" mode = execmode(s) elapsed(s)
end

@doc """
Returns the log file path for a given strategy.

$(TYPEDSIGNATURES)

This function returns the log file path for a given strategy. If the log file path is not set, it creates a new one based on the execution mode of the strategy.
"""
function runlog(s, name=lowercase(string(typeof(execmode(s)))))
    get!(s.attrs, :logfile, st.logpath(s; name))
end

@doc """
Checks if a given strategy is running.

$(TYPEDSIGNATURES)

This function checks if a given strategy is currently running. It returns `true` if the strategy is running, and `false` otherwise.
"""
function isrunning(s::Strategy{<:Union{Paper,Live}})
    running = attr(s, :is_running, nothing)
    if isnothing(running)
        false
    else
        running[]
    end
end

export start!, stop!

include("utils.jl")
include("orders/utils.jl")
include("orders/state.jl")
include("orders/limit.jl")
include("orders/pong.jl")
include("positions/pong.jl")
