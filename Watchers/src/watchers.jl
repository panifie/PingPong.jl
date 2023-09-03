using Python
using TimeTicks
using DataStructures
using DataStructures: CircularBuffer
using Misc
using Data
using Data: rangeafter
using Lang: Option, safewait, safenotify, @lget!
using Processing.DataFrames: DataFrame
using Base.Threads: @spawn

function _tryfetch(w)::Bool
    result = lock(w._exec.fetch_lock) do
        w.last_fetch = now()
        try
            _fetch!(w, w._val)
        catch e
            e
        end::Union{Bool,Exception}
    end
    if w._stop
        try
            isstopped(w) || stop!(w)
            flush!(w)
        catch e
            logerror(w, e)
        end
        haskey(WATCHERS, w.name) && delete!(WATCHERS, w.name)
    end
    if result isa Exception
        logerror(w, result)
        false
    else
        safenotify(w.beacon.fetch)
        result
    end
end
const Enabled = Val{true}
const Disabled = Val{false}
_fetch_task(w, ::Enabled; kwargs...) = @spawn _tryfetch(w; kwargs...)
_fetch_task(w, ::Disabled; kwargs...) = @async _tryfetch(w; kwargs...)
function _schedule_fetch(w, timeout, threads; kwargs...)
    # skip fetching if already locked to avoid building up the queue
    islocked(w._exec.fetch_lock) && begin
        w.attempts += 1
        return nothing
    end
    waiting = Ref(true)
    try
        w[:task] = task = _fetch_task(w, Val(w._exec.threads); kwargs...)
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

function _timer!(w)
    isnothing(w._timer) || close(w._timer)
    w._timer = Timer(
        # NOTE: the callback for the timer requires 1 arg (the timer itself)
        (_) -> _schedule_fetch(w, w.interval.timeout, w._exec.threads),
        0;
        interval=convert(Second, w.interval.fetch).value,
    )
end

function _check_flush_interval(flush_interval, fetch_interval, cap)
    drop_time = cap * fetch_interval
    if flush_interval > drop_time
        @warn "Flush interval ($flush_interval) is too high, buffer element would be dropped in $drop_time."
    end
end

BufferEntry(T) = NamedTuple{(:time, :value),Tuple{DateTime,T}}
const HasFunction = NamedTuple{(:load, :process, :flush),NTuple{3,Bool}}
const Interval = NamedTuple{(:timeout, :fetch, :flush),NTuple{3,Millisecond}}
const Exec = NamedTuple{
    (:threads, :fetch_lock, :buffer_lock, :errors),
    Tuple{Bool,ReentrantLock,ReentrantLock,CircularBuffer{Tuple{Any,Vector}}},
}
const Capacity = NamedTuple{(:buffer, :view),Tuple{Int,Int}}
const Beacon = NamedTuple{(:fetch, :process, :flush),NTuple{3,Threads.Condition}}

@kwdef mutable struct Watcher22{T}
    const buffer::CircularBuffer{BufferEntry(T)}
    const name::String
    const has::HasFunction
    const interval::Interval
    const capacity::Capacity
    const beacon::Beacon
    const _exec::Exec
    const _val::Val
    _stop = false
    _timer::Option{Timer} = nothing
    attempts::Int = 0
    last_fetch::DateTime = DateTime(0)
    last_flush::DateTime = DateTime(0)
    attrs::Dict{Symbol,Any} = Dict()
end
@doc """ Watchers manage data, they pull from somewhere, keep a cache in memory, and optionally flush periodically to persistent storage.

 - `buffer`: A [CircularBuffer](https://juliacollections.github.io/DataStructures.jl/latest/circ_buffer/) of default length `1000` of the watcher type parameter.
 - `name`: The name is used for dispatching.
 - `has`: flags that show which callbacks are enabled between `load`, `process` and `flush`.
 - `fetch_timeout`: How much time to wait for the fetcher function.
 - `fetch_interval`: the `Period` with which `_fetch!` function will be called.
 - `flush_interval`: the `Period` with which `_flush!` function will be called.
 - `capacity`: controls the size of the buffer and the processed container.
 - `beacon`: Conditions notified on successful fetch, process and flush events.
 - `threads`: flag to enable to execute fetching in a separate thread.
 - `attempts`: In cause of fetching failure, tracks how many consecutive fails have occurred. It resets after a successful fetch operation.
 - `last_fetch`: the most recent time a fetch operation failed.
 - `last_flush`: the most recent time the flush function was called.
 - `_timer`: A [Timer](https://docs.julialang.org/en/v1/base/base/#Base.Timer), handles calling the function that fetches the data.
 """
Watcher = Watcher22
const WATCHERS = Misc.ConcurrentCollections.ConcurrentDict{String,Watcher}()

@doc """ Instantiate a watcher.

- `T`: The type of the underlying `CircularBuffer`
- `len`: length of the circular buffer.
- `start`: If `true`(default), the watcher will start fetching asap.

!!! warning "asyncio vs threads"
    Both `_fetch!` and `_flush!` callbacks assume non-blocking asyncio like behaviour. If instead your functions require \
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
    w = Watcher22{T}(;
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
            threads, ReentrantLock(), ReentrantLock(), CircularBuffer{Tuple{Any,Vector}}(10)
        )),
        _val=val,
        attrs,
    )
    @assert applicable(_fetch!, w, w._val) "`_fetch!` function not declared for `Watcher` \
        with id $(w.name) (It must accept a `Watcher` as argument, and return a boolean)."
    w = finalizer(close, w)
    @debug "_init $name"
    _init!(w, w._val)
    @debug "_load for $name? $(w.has.load)"
    w.has.load && _load!(w, w._val)
    w.last_flush = now() # skip flush on start
    @debug "setting timer for $name"
    start && _timer!(w)
    @debug "watcher $name initialized!"
    w
end

function watcher(T::Type, name::String, args...; kwargs...)
    if haskey(WATCHERS, name)
        @warn "Replacing watcher $name with new instance."
        pop!(WATCHERS, name) |> close
    end
    WATCHERS[name] = _watcher(T, name, args...; kwargs...)
end

_closeall() = asyncmap(close, values(WATCHERS))
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
