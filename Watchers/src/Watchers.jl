@doc "Watchers are data feeds, that keep track of stale data."
module Watchers
using Python
using TimeTicks
using DataStructures
using DataStructures: CircularBuffer
using Misc
using Data
using Lang: Option, safewait, safenotify
using Base.Threads: @spawn
using Processing.DataFrames: DataFrame

function _tryfetch(w)::Bool
    # skip fetching if already locked to avoid building up the queue
    islocked(w._exec.fetch_lock) && return true
    result = @lock w._exec.fetch_lock begin
        w.last_fetch = now()
        _fetch!(w, w._val)
    end
    if result isa Exception
        logerror(w, result)
        false
    else
        @debug @assert result
        safenotify(w.beacon)
        true
    end
end
function _schedule_fetch(w, timeout, threads; kwargs...)
    fetcher_task =
        threads ? (@spawn _tryfetch(w; kwargs...)) : (@async _tryfetch(w; kwargs...))
    @async begin
        sleep(timeout)
        safenotify(fetcher_task.donenotify)
    end
    safewait(fetcher_task.donenotify)
    if istaskdone(fetcher_task) && fetch(fetcher_task)
        w.attempts = 0
        w.has.process && process!(w)
        w.has.flush && flush!(w; force=false, sync=false)
    else
        w.attempts += 1
    end
end

function _timer!(w)
    isnothing(w._timer) || close(w._timer)
    w._timer = Timer(
        # NOTE: the callback for the timer requires 1 arg (the timer itself)
        (_) -> _schedule_fetch(w, w.interval.timeout, w._exec.threads),
        0;
        interval=convert(Second, w.interval.fetch).value
    )
end

BufferEntry(T) = NamedTuple{(:time, :value),Tuple{DateTime,T}}
const HasFunction = NamedTuple{(:load, :process, :flush),NTuple{3,Bool}}
const Interval = NamedTuple{(:timeout, :fetch, :flush),NTuple{3,Millisecond}}
const Exec = NamedTuple{
    (:threads, :fetch_lock, :buffer_lock, :errors),
    Tuple{Bool,ReentrantLock,ReentrantLock,CircularBuffer{Tuple{Any,Vector}}},
}
const Capacity = NamedTuple{(:buffer, :view),Tuple{Int,Int}}

@kwdef mutable struct Watcher20{T}
    const buffer::CircularBuffer{BufferEntry(T)}
    const name::String
    const has::HasFunction
    const interval::Interval
    const capacity::Capacity
    const beacon::Threads.Condition
    const _exec::Exec
    const _val::Val
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
 - `beacon`: A condition that is notified whenever a successful fetch is performed.
 - `threads`: flag to enable to execute fetching in a separate thread.
 - `attempts`: In cause of fetching failure, tracks how many consecutive fails have occurred. It resets after a successful fetch operation.
 - `last_fetch`: the most recent time a fetch operation failed.
 - `last_flush`: the most recent time the flush function was called.
 - `_timer`: A [Timer](https://docs.julialang.org/en/v1/base/base/#Base.Timer), handles calling the function that fetches the data.
 """
Watcher = Watcher20

include("errors.jl")

@doc """ Instantiate a watcher.

- `T`: The type of the underlying `CircularBuffer`
- `len`: length of the circular buffer.
- `start`: If `true`(default), the watcher will start fetching asap.

!!! warning "asyncio vs threads"
    Both `_fetch!` and `_flush!` callbacks assume non-blocking asyncio like behaviour. If instead your functions require \
    high computation, pass `threads=true`, you will have to ensure thread safety.
"""
function watcher(
    T::Type,
    name;
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
    attrs=Dict()
)
    @debug "new watcher: $name"
    w = Watcher20{T}(;
        buffer=CircularBuffer{BufferEntry(T)}(buffer_capacity),
        name=String(name),
        has=HasFunction((load, process, flush)),
        interval=Interval((fetch_timeout, fetch_interval, flush_interval)),
        capacity=Capacity((buffer_capacity, view_capacity)),
        beacon=Threads.Condition(),
        _exec=Exec((
            threads, ReentrantLock(), ReentrantLock(), CircularBuffer{Tuple{Any,Vector}}(10)
        )),
        _val=Val(Symbol(name)),
        attrs
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

@doc "Helper function to push a vector of values to the watcher buffer."
function pushstart!(w::Watcher, vec)
    isempty(vec) && return nothing
    time = now()
    start_offset = min(w.buffer.capacity, size(vec, 1))
    pushval(x) = push!(w.buffer, (; time, value=x.value))
    foreach(pushval, @view(vec[(end-start_offset+1):end]))
end

@doc "Helper function to push a new value to the watcher buffer if it is different from the last one."
function pushnew!(w::Watcher, value)
    # NOTE: use object inequality to avoid non determinsm
    if !isnothing(value) && (isempty(w.buffer) || value !== w.buffer[end].value)
        push!(w.buffer, (time=now(), value))
    end
end

_isserialized(w::Watcher) = get!(w.attrs, :serialized, false)

@doc "Save function for watcher data, saves to the default `DATA_PATH` \
located lmdb instance using serialization."
function default_flusher(w::Watcher, key; reset=false, buf=w.buffer)
    isempty(buf) && return nothing
    most_recent = last(buf)
    last_flushed = get!(w.attrs, :last_flushed, (; time=DateTime(0)))
    if most_recent.time > last_flushed.time
        recent_slice = after(buf, last_flushed; by=x -> x.time)
        save_data(
            zilmdb(), key, recent_slice; serialize=_isserialized(w), overwrite=true, reset
        )
        w.attrs[:last_flushed] = most_recent
    end
end
default_flusher(w::Watcher) = default_flusher(w, w.name)
@doc "Load function for watcher data, loads from the default `DATA_PATH` \
located lmdb instance using serialization."
function default_loader(w::Watcher, key)
    get!(w.attrs, :loaded, false) && return nothing
    v = load_data(zilmdb(), key; serialized=_isserialized(w))
    !isnothing(v) && pushstart!(w, v)
    w.has.process && process!(w)
    w.attrs[:loaded] = true
end
default_loader(w::Watcher) = default_loader(w, w.name)

@doc "Processes the values of a watcher buffer into a dataframe.
To be used with: `default_init` and `default_get`
"
function default_process(w::Watcher, appendby::Function)
    isempty(w.buffer) && return nothing
    last_p = w.attrs[:last_processed]
    if isnothing(last_p)
        appendby(w.attrs[:view], w.buffer, w.capacity.view)
    else
        range = rangeafter(w.buffer, last_p; by=x -> x.time)
        length(range) > 0 &&
            appendby(w.attrs[:view], view(w.buffer, range), w.capacity.view)
    end
    w.attrs[:last_processed] = w.buffer[end]
end
function default_init(w::Watcher, dataview=DataFrame())
    w.attrs[:view] = dataview
    w.attrs[:last_processed] = nothing
    w.attrs[:checks] = Val(:off)
    w.attrs[:serialized] = true
end
default_get(w::Watcher) = w.attrs[:view]

_notimpl(sym, w) = throw(error("`$sym` Not Implemented for watcher `$(w.name)`"))
@doc "May run after a successful fetch operation, according to the `flush_interval`. It spawns a task."
_flush!(w::Watcher, ::Val) = default_flusher(w, w.attrs[:key])
@doc "Called once on watcher creation, used to pre-fill the watcher buffer."
_load!(w::Watcher, ::Val) = default_loader(w, w.attrs[:key])
@doc "Appends new data to the watcher buffer, returns `true` when new data is added, `false` otherwise."
_fetch!(w::Watcher, ::Val) = _notimpl(fetch!, w)
@doc "Processes the watcher data, called everytime the watcher fetches new data."
_process!(w::Watcher, ::Val) = default_process(w, Data.DFUtils.appendmax!)
@doc "Function to run on watcher initialization, it runs before `_load!`."
_init!(w::Watcher, ::Val) = default_init(w)

@doc "Returns the processed `view` of the watcher data."
_get(w::Watcher, ::Val) = default_get(w)
@doc "Returns the processed `view` of the watcher data. Accessible also as a `view` property of the watcher object."
Base.get(w::Watcher) = _get(w, w._val)
@doc "If the watcher manager a group of things that it is fetching, `_push!` should add an element to it."
_push!(w::Watcher, ::Val) = _notimpl(push!, w)
@doc "Same as `_push!` but for removing elements."
_pop!(w::Watcher, ::Val) = _notimpl(pop!, w)
function _delete!(w::Watcher, ::Val)
    delete!(zilmdb().group, get!(w.attrs, :key, w.name))
    nothing
end
@doc "Executed before starting the timer."
_start!(_::Watcher, ::Val) = nothing
@doc "Executed after the timer has been stopped."
_stop!(_::Watcher, ::Val) = nothing
@doc "Deletes all watcher data from storage backend. Also empties the buffer."
function Base.delete!(w::Watcher)
    _delete!(w, w._val)
    empty!(w.buffer)
end
function _deleteat!(w::Watcher, ::Val; from=nothing, to=nothing, kwargs...)
    k = get!(w.attrs, :key, w.name)
    z = load_data(zilmdb(), k; as_z=true)
    zdelete!(z, from, to; serialized=_isserialized(w), kwargs...)
    # TODO generalize this searchsorted based deletion function
    if isnothing(from)
        if isnothing(to)
            return nothing
        else
            to_idx = searchsortedlast(w.buffer, (; time=to); by=x -> x.time)
            deleteat!(w.buffer, firstindex(w.buffer, 1):to_idx)
        end
    elseif isnothing(to)
        from_idx = searchsortedfirst(w.buffer, (; time=from); by=x -> x.time)
        deleteat!(w.buffer, (from_idx+1):lastindex(w.buffer, 1))
    else
        from_idx = searchsortedfirst(w.buffer, (; time=from); by=x -> x.time)
        to_idx = searchsortedlast(w.buffer, (; time=to); by=x -> x.time)
        deleteat!(w.buffer, (from_idx+1):to_idx)
    end
end
@doc "Delete watcher data from storage backend within the date range specified."
function Base.deleteat!(w::Watcher, range::DateTuple)
    _deleteat!(w, w._val; from=range.start, to=range.stop)
end

@doc "Flush the watcher. If wait is `true`, block until flush completes."
function flush!(w::Watcher; force=true, sync=false)
    time_now = now()
    if force || time_now - w.last_flush > w.interval.flush
        t = @async begin
            result = @lock w._exec.buffer_lock begin
                w.last_flush = time_now
                _flush!(w, w._val)
            end
            ifelse(result isa Exception, logerror(w, result), result)
        end
    end
    sync && wait(t)
    nothing
end
@doc "Fetches a new value from the watcher ignoring the timer. If `reset` is `true` the timer is reset and
polling will resume after the watcher `interval`."
function fetch!(w::Watcher; reset=false, kwargs...)
    try
        _schedule_fetch(w, w.interval.timeout, w._exec.threads; kwargs...)
        reset && _timer!(w)
    catch e
        logerror(w, e, stacktrace(catch_backtrace()))
    finally
        return isempty(w.buffer) ? nothing : last(w.buffer).value
    end
end

function process!(w::Watcher, args...; kwargs...)
    @logerror w _process!(w, w._val, args...; kwargs...)
end
load!(w::Watcher, args...; kwargs...) = _load!(w, w._val, args...; kwargs...)
init!(w::Watcher, args...; kwargs...) = _init!(w, w._val, args...; kwargs...)
@doc "Add `v` to the things the watcher is fetching."
function Base.push!(w::Watcher, v, args...; kwargs...)
    _push!(w, w._val, v, args...; kwargs...)
end
@doc "Remove `v` from the things the watcher is fetching."
function Base.pop!(w::Watcher, v, args...; kwargs...)
    _pop!(w, w._val, v, args...; kwargs...)
end

@doc "True if last available data entry is older than `now() + fetch_interval + fetch_timeout`."
function isstale(w::Watcher)
    w.attempts > 0 ||
        w.last_fetch < now() - w.interval.fetch_interval - w.interval.fetch_timeout
end
Base.last(w::Watcher) = last(w.buffer)
Base.length(w::Watcher) = length(w.buffer)
Base.close(w::Watcher; doflush=true) = @async begin
    @lock w._exec.fetch_lock begin
        stop!(w)
        doflush && flush!(w)
        nothing
    end
end
Base.empty!(w::Watcher) = empty!(w.buffer)
Base.getproperty(w::Watcher, p::Symbol) = begin
    if p == :view
        Base.get(w)
    else
        getfield(w, p)
    end
end
@doc "Stops the watcher timer."
stop!(w::Watcher) = begin
    @assert isstarted(w) "Tried to stop an already stopped watcher."
    Base.close(w._timer)
    _stop!(w, w._val)
    nothing
end
@doc "Resets the watcher timer."
start!(w::Watcher) = begin
    @assert isstopped(w) "Tried to start an already started watcher."
    empty!(w._exec.errors)
    _start!(w, w._val)
    _timer!(w)
    nothing
end
@doc "True if timer is not running."
isstopped(w::Watcher) = isnothing(w._timer) || !isopen(w._timer)
@doc "True if timer is running."
isstarted(w::Watcher) = !isnothing(w._timer) && isopen(w._timer)

function Base.show(out::IO, w::Watcher)
    tps = "$(typeof(w))"
    write(out, "$(length(w.buffer))-element ")
    if length(tps) > 80
        write(out, @view(tps[begin:40]))
        write(out, "...")
        write(out, @view(tps[(end-40):end]))
    else
        write(out, tps)
    end
    write(out, "\nName: ")
    write(out, w.name)
    write(out, "\nIntervals: ")
    write(out, "$(compact(w.interval.timeout))(TO)")
    write(out, ", $(compact(w.interval.fetch))(FE)")
    write(out, ", $(compact(w.interval.flush))(FL)")
    write(out, "\nFetched: ")
    write(out, "$(w.last_fetch) busy: $(islocked(w._exec.fetch_lock))")
    write(out, "\nFlushed: ")
    write(out, "$(w.last_flush)")
    write(out, "\nActive: ")
    write(out, "$(isstarted(w))")
    write(out, "\nAttemps: ")
    write(out, "$(w.attempts)")
    e = lasterror(w)
    if !isnothing(e)
        write(out, "\nErrors: ")
        Base.show_backtrace(out, e[2])
        # avoid recursion
        if isempty(Base.catch_stack())
            Base.showerror(out, e[1])
        end
    end
end
Base.display(w::Watcher) =
    try
        buf = IOBuffer()
        show(buf, w)
        Base.println(String(take!(buf)))
    catch
        close(buf)
    end

export Watcher, watcher, isstale, default_loader, default_flusher
export default_process, default_init, default_get
export pushnew!, pushstart!, start!, stop!, isstarted, isstopped, process!, load!, init!

include("apis/coinmarketcap.jl")
include("apis/coingecko.jl")
include("apis/coinpaprika.jl")
include("impls/impls.jl")

end
