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
using .Misc.Lang: @lget!, @deassert, Option, @logerror, @debug_backtrace
using .Executors.Strategies: MarginStrategy, Strategy, Strategies as st, ping!
using .Executors.Strategies
using .Instances: MarginInstance
using .Instances.Exchanges: CcxtTrade
using .Instances.Data.DataStructures: CircularBuffer
using SimMode: AnyMarketOrder, AnyLimitOrder
import .Executors: pong!
import .Misc: start!, stop!, isrunning

const TradesCache = Dict{AssetInstance,CircularBuffer{CcxtTrade}}()

_maintf(s) = string(s.timeframe)
_opttf(s) = string(attr(s, :timeframe, nothing))
_timeframes(s) = join(string.(s.config.timeframes), " ")
_cash_total(s) = cnum(st.current_total(s, lastprice))
_assets(s) =
    let str = join(getproperty.(st.assets(s), :raw), ", ")
        str[begin:min(length(str), displaysize()[2] - 1)]
    end
function header(s::Strategy, throttle)
    "Starting strategy $(nameof(s)) in $(nameof(typeof(execmode(s)))) mode!

        throttle: $throttle
        timeframes: $(_maintf(s)) (main), $(_maintf(s)) (optional), $(_timeframes(s)...) (extras)
        cash: $(cash(s)) [$(_cash_total(s))]
        assets: $(_assets(s))
        margin: $(marginmode(s))
        "
end

function log(s::Strategy)
    long, short, liq = st.trades_count(s, Val(:positions))
    cv = s.cash
    comm = s.cash_committed
    inc = orderscount(s, Val(:increase))
    red = orderscount(s, Val(:reduce))
    tot = st.current_total(s, lastprice)
    @info string(nameof(s), "@", nameof(exchange(s))) time = now() cash = cv committed =
        comm balance = tot inc_orders = inc red_orders = red long_trades = long short_trades =
        short liquidations = liq
end

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

function _doping(s; throttle, loghandle, flushlog, log_lock)
    is_running = attr(s, :is_running)
    @assert isassigned(is_running)
    setattr!(s, now(), :is_start)
    setattr!(s, missing, :is_stop)
    try
        @sync while is_running[]
            try
                log(s)
                flushlog(loghandle)
                ping!(s, now(), nothing)
                sleep(throttle)
            catch e
                e isa InterruptException && begin
                    is_running[] = false
                    rethrow(e)
                end
                @debug_backtrace
                @async lock(log_lock) do
                    try
                        @logerror loghandle
                    catch
                        @debug "Failed to log $(now())"
                    end
                end
                sleep(throttle)
            end
        end
    catch e
        e isa InterruptException && rethrow(e)
        @error e
    finally
        is_running[] = false
        setattr!(s, now(), :is_stop)
    end
end

function start!(
    s::Strategy{<:Union{Paper,Live}}; throttle=throttle(s), doreset=false, foreground=false
)
    local startinfo, flushlog, log_lock
    @lock s begin
        attrs = s.attrs
        first_start = !haskey(attrs, :is_running)
        if doreset && first_start # only set defaults on first run
            default!(s)
            reset!(s)
        end

        if first_start
            s[:is_running] = Ref(true)
        elseif s[:is_running][]
            @error "start: strategy already running" s = nameof(s)
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
        logfile = runlog(s)
        loghandle = open(logfile, "w")
        logger = SimpleLogger(open(logfile, "w"))
        try
            s[:run_task] = @async with_logger(logger) do
                @info startinfo
                _doping(s; throttle, loghandle, flushlog, log_lock)
            end
        finally
            flush(loghandle)
            close(loghandle)
        end
    end
end

function elapsed(s::Strategy{<:Union{Paper,Live}})
    attrs = s.attrs
    max(
        Millisecond(0),
        @coalesce(get(attrs, :is_stop, missing), now()) -
        @coalesce(get(attrs, :is_start, missing), now()),
    )
end

function stop!(s::Strategy{<:Union{Paper,Live}})
    task = @lock s begin
        running = attr(s, :is_running, nothing)
        task = attr(s, :run_task, nothing)
        if isnothing(running)
            @assert isnothing(task) || istaskdone(task)
            return nothing
        else
            @assert running[] || istaskdone(task)
        end
        running[] = false
        task
    end
    @info "strategy: stopped" mode = execmode(s) elapsed(s)
    if task isa Task
        wait(task)
    end
end

function runlog(s, name=lowercase(string(execmode(s))))
    get!(s.attrs, :logfile, st.logpath(s; name))
end

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
