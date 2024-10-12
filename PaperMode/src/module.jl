using Fetch: Fetch, pytofloat
using SimMode
using SimMode.Executors
using Base: with_logger
using .Executors: orders, orderscount
using .Executors.OrderTypes
using .Executors.TimeTicks
using .Executors.Instances
using .Executors.Misc
using .Executors.Instruments: compactnum as cnum
using .Misc.ConcurrentCollections: ConcurrentDict
using .Misc.TimeToLive: safettl
using .Misc.LoggingExtras
using .Misc.Lang: @lget!, @ifdebug, @deassert, Option, @writeerror, @debug_backtrace
using .Executors.Strategies: MarginStrategy, Strategy, Strategies as st, ping!
using .Executors.Strategies
using .Instances: MarginInstance
using .Instances.Exchanges: CcxtTrade
using .Instances.Data.DataStructures: CircularBuffer
using SimMode: AnyMarketOrder, AnyLimitOrder
import .Executors: pong!
import .Misc: start!, stop!, isrunning, sleep_pad, LOGGING_GROUPS

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
NOTE: ensure this doesn't use the strategy lock.
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
    inc, red = orderscount(s, Val(:inc_red))
    tot = st.current_total(s; price_func=lastprice, local_bal=true)
    @info string(nameof(s), "@", nameof(exchange(s))) time = now() cash = cv committed =
        comm balance = tot inc_orders = inc red_orders = red long_trades = long short_trades =
        short liquidations = liq
end

@doc """
Executes the main loop of the strategy.

$(TYPEDSIGNATURES)

This function executes the main loop of the strategy, logging the state, pinging the strategy, and sleeping for the throttle duration. It handles exceptions and ensures the strategy stops running when an interrupt exception is thrown.
"""
function _doping(s; throttle)
    is_running = attr(s, :is_running)
    @assert isassigned(is_running)
    setattr!(s, now(), :is_start)
    setattr!(s, missing, :is_stop)
    ping_start = DateTime(0)
    prev_cash = s.cash.value
    s_cash = s.cash
    event!(s, StrategyEvent, :strategy_started, s; start_time=s.is_start)
    try
        while is_running[]
            try
                if s_cash != prev_cash
                    log(s)
                    prev_cash = s_cash.value
                end
                ping_start = now()
                ping!(s, now(), nothing)
                sleep_pad(ping_start, throttle)
            catch e
                e isa InterruptException && begin
                    is_running[] = false
                    rethrow(e)
                end
                @debug_backtrace
                sleep_pad(ping_start, throttle)
            end
        end
    catch e
        e isa InterruptException && rethrow(e)
        @error e
    finally
        is_running[] = false
        setattr!(s, now(), :is_stop)
        event!(s, StrategyEvent, :strategy_stopped, s; start_time=s.is_stop)
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
    ping!(s, StartStrategy())
    local startinfo
    s[:stopped] = false
    @debug "start: locking"
    @lock s begin
        @debug "start: locked"
        attrs = s.attrs
        first_start = !haskey(attrs, :is_running)
        # HACK: `default!` locks the strategy during syncing, so we unlock here to avoid deadlocks.
        # This should not be required since the lock is reentrant.
        # Does syncing use multiple threads? It should not..
        unlock(s)
        try
            if doreset
                @debug "start: reset"
                reset!(s)
            elseif first_start
                # only set defaults on first run
                @debug "start: defaults"
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
            @debug "start: is_running set"
            s[:is_running][] = true
        end
        @deassert attr(s, :is_running)[]

        @debug "start: header"
        startinfo = header(s, throttle)
        @debug "start: unlocked"
    end
    logger = s[:logger]
    if foreground
        s[:run_task] = nothing
        with_logger(logger) do
            @info startinfo
            _doping(s; throttle)
        end
    else
        s[:run_task] = @async with_logger(logger) do
            @info startinfo
            _doping(s; throttle)
        end
        return nothing
    end
end

_compressor(file) = run(`gzip $(file)`)
function strategy_logger!(s)
    logdir, logname = let file = runlog(s)
        dirname(file), splitext(basename(file))[1]
    end
    esc_logname = replace(logname, r"(.)" => s"\\\1")

    all_levels = [Logging.Debug, Logging.Info, Logging.Warn, Logging.Error]

    # Create a logger for each level
    level_loggers = Dict{LogLevel, AbstractLogger}()
    for level in all_levels
        if level >= s[:log_level]
            level_str = lowercase(string(level))
            esc_level_str = replace(level_str, r"(.)" => s"\\\1")
            rotate_logger = DatetimeRotatingFileLogger(
                logdir,
                string(esc_logname, "-", esc_level_str, "-", raw"YYYY-mm-dd.\l\o\g");
                rotation_callback=_compressor,
            )
            ts_logger = timestamp_logger(rotate_logger)
            level_loggers[level] = ts_logger
        end
    end

    # Create a filtered logger for each level
    filtered_loggers = []
    for (level, logger) in level_loggers
        filtered_logger = EarlyFilteredLogger(logger) do log_args
            log_args.level == level
        end
        push!(filtered_loggers, filtered_logger)
    end

    # Combine all loggers
    file_logger = TeeLogger(filtered_loggers...)

    # Create a MinLevelLogger for the global logger (stdout)
    min_level_global_logger = MinLevelLogger(global_logger(), s[:log_level])

    # Combine file logger with the min-level global logger
    s[:logger] = TeeLogger(min_level_global_logger, file_logger)
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
    @debug "stop: locking" islocked(s)
    @lock s begin
        @debug "stop: locked"
        running = attr(s, :is_running, missing)
        task = attr(s, :run_task, missing)
        if running isa Ref{Bool}
            running[] = false
        end
        if istaskrunning(task)
            waitforcond(task.donenotify, throttle(s))
            if istaskrunning(task)
                @warn "strategy: hanging task, killing"
                Threads.@spawn kill_task(task)
            end
        end
    end
    ping!(s, StopStrategy())
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

function logmaxlines(s)
    get!(s.attrs, :logfile_maxlines, 10000)
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
