using Fetch: Fetch
using Fetch.Data
using Fetch.Python
using Fetch.Misc
using .Data: rangeafter
using .Data.DataStructures: CircularBuffer
using .Data.DataFrames: DataFrame
using .Misc
using .Misc.TimeTicks
using .Misc.Lang: Option, safewait, safenotify, @lget!, Lang
using .Misc: after, truncate_file
using Base.Threads: @spawn
using JSON3

@doc """ Attempts to fetch data for a watcher

$(TYPEDSIGNATURES)

This function tries to fetch data for a given watcher. It locks the watcher, updates the last fetch time, and attempts to fetch data. If the fetch is successful, it returns `true`, otherwise it logs the error and returns `false`. It also handles stopping the watcher if needed.
"""
function _tryfetch(w)::Bool
    result = @lock w begin
        res = try
            _fetch!(w, _val(w))
        catch e
            e
        end::Union{Bool,Exception}
        w.last_fetch = now()
        res
    end
    if w._stop
        try
            isstopped(w) || stop!(w)
            flush!(w)
        catch e
            logerror(w, e)
        end
        prev_w = pop!(WATCHERS, w.name, missing)
        if !ismissing(prev_w) && isstarted(prev_w)
            stop!(w)
        end
    end
    if result isa Exception
        logerror(w, result)
        false
    elseif result isa Bool
        result
    else
        logerror(w, ErrorException("Fetch result is not a bool ($(w.name))"))
        false
    end
end
const Enabled = Val{true}
const Disabled = Val{false}
_fetch_task(w, ::Enabled; kwargs...) = @spawn _tryfetch(w; kwargs...)
_fetch_task(w, ::Disabled; kwargs...) = @async _tryfetch(w; kwargs...)
@doc """ Schedules a fetch operation for a watcher

$(TYPEDSIGNATURES)

This function schedules a fetch operation for a given watcher. It checks if the watcher is locked and if not, it creates a task to fetch data. It also handles timeouts and increments the attempt counter in case of failure. The function ensures that the fetch operation is thread-safe and handles any exceptions that might occur during the fetch operation.
"""
function _schedule_fetch(w, timeout, threads; kwargs...)
    # skip fetching if already locked to avoid building up the queue
    islocked(w) && begin
        w.attempts += 1
        return nothing
    end
    waiting = Ref(true)
    try
        task = _fetch_task(w, Val(w._exec.threads); kwargs...)
        @async let slept = @lget! w.attrs :fetch_timeout Ref(0.0)
            while waiting[] && slept[] < timeout
                slept[] += 0.1
                sleep(0.1)
            end
            slept[] > timeout && safenotify(task.donenotify)
        end
        safewait(task.donenotify)
        if istaskdone(task) && fetch(task)
            w.attempts = 0
            w.has.process && process!(w)
            w.has.flush && flush!(w; force=false, sync=false)
        else
            w.attempts += 1
        end
    catch e
        w.attempts += 1
        logerror(w, e, stacktrace(catch_backtrace()))
    finally
        waiting[] = false
        w[:fetch_timeout][] = Inf
    end
end

@doc "`_timer` is an optional Timer object used to schedule fetch operations for a watcher."
function _timer!(w)
    if !isnothing(w._timer)
        close(w._timer)
    end
    # NOTE: the callback for the timer requires 1 arg (the timer itself)
    timer_fetch_callback(_) = _schedule_fetch(w, w.interval.timeout, w._exec.threads)
    interval = round(w.interval.fetch, Second, RoundUp).value
    w._timer = Timer(timer_fetch_callback, 0; interval)
end

@doc """ Checks the appropriateness of the flush interval

$(TYPEDSIGNATURES)

This function checks if the flush interval is greater than the time it would take to drop an element from the buffer (calculated as the product of the fetch interval and the buffer capacity). If the flush interval is too high, a warning is issued.
"""
function _check_flush_interval(flush_interval, fetch_interval, cap)
    if cap > 1
        drop_time = cap * fetch_interval
        if flush_interval > drop_time
            @warn "Flush interval ($flush_interval) is too high, buffer element would be dropped in $drop_time."
        end
    end
end

@doc "The single entry in the buffer"
BufferEntry(T) = NamedTuple{(:time, :value),Tuple{DateTime,T}}
@doc "The flags that control which operations are performed by the watcher"
const HasFunction = NamedTuple{(:load, :process, :flush),NTuple{3,Bool}}
@doc "The interval parameters for the watcher"
const Interval = NamedTuple{(:timeout, :fetch, :flush),NTuple{3,Millisecond}}
@doc "The execution variables for the watcher"
const Exec = NamedTuple{
    (:threads, :fetch_lock, :buffer_lock, :errors),
    Tuple{Bool,SafeLock,SafeLock,CircularBuffer{Tuple{Any,Vector}}},
}
@doc "The capacity parameters for the watcher"
const Capacity = NamedTuple{(:buffer, :view),Tuple{Int,Int}}
@doc "The flags that control which operations are notified by the watcher"
const Beacon = NamedTuple{(:fetch, :process, :flush),NTuple{3,Threads.Condition}}

@doc """ Watchers manage data, they pull from somewhere, keep a cache in memory, and optionally flush periodically to persistent storage.

$(FIELDS)

A `Watcher` is a mutable struct that manages data. It pulls data from a source, keeps a cache in memory, and optionally flushes the data to persistent storage periodically. The struct contains fields for managing the buffer, scheduling fetch operations, and handling fetch failures.
"""
@kwdef mutable struct Watcher{T}
    "A CircularBuffer of the watcher type parameter"
    const buffer::CircularBuffer{BufferEntry(T)}
    "The name is used for dispatching"
    const name::String
    "Flags that show which callbacks are enabled between `load`, `process` and `flush`"
    const has::HasFunction
    "The interval parameters for the watcher"
    const interval::Interval
    "Controls the size of the buffer and the processed container"
    const capacity::Capacity
    "Conditions notified on successful fetch, process and flush events"
    const beacon::Beacon
    "The execution variables for the watcher"
    const _exec::Exec
    "The watcher type parameter"
    const _val::Val
    "Flag to stop the watcher"
    _stop = false
    "A Timer object used to schedule fetch operations for a watcher"
    _timer::Option{Timer} = nothing
    "Tracks how many consecutive fails have occurred in case of fetching failure"
    attempts::Int = 0
    "The most recent time a fetch operation failed"
    last_fetch::DateTime = DateTime(0)
    "The most recent time the flush function was called"
    last_flush::DateTime = DateTime(0)
    "Additional attributes for the watcher"
    attrs::Dict{Symbol,Any} = Dict{Symbol,Any}()
end
const WATCHERS = Misc.ConcurrentCollections.ConcurrentDict{String,Watcher}()

@doc """ Instantiate a watcher.

$(TYPEDSIGNATURES)

This function creates a new watcher with the specified parameters.
It checks the flush interval, initializes the watcher, loads data if necessary, and sets a timer for the watcher if the `start` parameter is `true`.
It also ensures that the `_fetch!` function is applicable for the watcher.


!!! warning "asyncio vs threads"
    BuyOrSell `_fetch!` and `_flush!` callbacks assume non-blocking asyncio like behaviour. If instead your functions require \
    high computation, pass `threads=true`, you will have to ensure thread safety.
"""
function _watcher(
    T::Type,
    name::String,
    val::Val=Val(Symbol(name));
    start=true,
    load=true,
    process=false,
    flush=false,
    threads=false,
    fetch_timeout=Second(5),
    fetch_interval=Second(30),
    flush_interval=Second(360),
    buffer_capacity=100,
    view_capacity=1000,
    attrs=Dict(),
)
    flush && _check_flush_interval(flush_interval, fetch_interval, buffer_capacity)
    @debug "new watcher: $name"
    w = Watcher{T}(;
        buffer=CircularBuffer{BufferEntry(T)}(buffer_capacity),
        name=String(name),
        has=HasFunction((load, process, flush)),
        interval=Interval((fetch_timeout, fetch_interval, flush_interval)),
        capacity=Capacity((buffer_capacity, view_capacity)),
        beacon=(;
            fetch=Threads.Condition(),
            process=Threads.Condition(),
            flush=Threads.Condition(),
        ),
        _exec=Exec((
            threads, SafeLock(), SafeLock(), CircularBuffer{Tuple{Any,Vector}}(10)
        )),
        _val=val,
        attrs,
    )
    @assert applicable(_fetch!, w, _val(w)) "`_fetch!` function not declared for `Watcher` \
        with id $(w.name) (It must accept a `Watcher` as argument, and return a boolean)."
    w = finalizer(close, w)
    @debug "_init $name"
    _init!(w, _val(w))
    logfile = get(attrs, :logfile, nothing)
    if !isnothing(logfile)
        maxlines = get(attrs, :logfile_maxlines, 10000)
        @debug "truncating logfile" logfile maxlines
        truncate_file(logfile, maxlines)
    end
    @debug "_load for $name? $(w.has.load)"
    w.has.load && _load!(w, _val(w))
    w.last_flush = now() # skip flush on start
    @debug "setting timer for $name"
    start && _timer!(w)
    @debug "watcher $name initialized!"
    w
end

@doc """ Instantiate a watcher and add it to the global watchers list.

$(TYPEDSIGNATURES)

This function creates a new watcher with the specified parameters and adds it to the global `WATCHERS` list. If a watcher with the same name already exists in the list, it replaces the old watcher with the new one.
"""
function watcher(T::Type, name::String, args...; kwargs...)
    prev_w = pop!(WATCHERS, name, missing)
    if !ismissing(prev_w)
        close(prev_w)
        @warn "Replacing watcher $name with new instance."
    end
    WATCHERS[name] = _watcher(T, name, args...; kwargs...)
end

@doc "Close all watchers."
_closeall() = begin
    asyncmap(close, values(WATCHERS))
    empty!(WatchersImpls.OHLCV_CACHE)
end
atexit(_closeall)

include("errors.jl")
include("defaults.jl")
include("functions.jl")

export Watcher, watcher, isstale, default_loader, default_flusher
export default_process, default_init, default_get
export pushnew!, pushstart!, start!, stop!, isstarted, isstopped, process!, load!, init!

include("apis/coinmarketcap.jl")
include("apis/coingecko.jl")
include("apis/coinpaprika.jl")
include("impls/impls.jl")

using .WatchersImpls: iswatchfunc
export iswatchfunc
