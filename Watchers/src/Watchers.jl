@doc "Watchers are data feeds, that keep track of stale data."
module Watchers
using Python
using TimeTicks
using DataStructures
using DataStructures: CircularBuffer
using Data
using Lang: Option
using Base.Threads: @spawn
using Base: acquire, Semaphore, release
using Processing.DataFrames: DataFrame

safenotify(cond) = begin
    lock(cond)
    notify(cond)
    unlock(cond)
end
safewait(cond) = begin
    lock(cond)
    wait(cond)
    unlock(cond)
end
@doc "Same as `@lock` but with `acquire` and `release`."
macro acquire(cond, code)
    quote
        temp = $(esc(cond))
        acquire(temp)
        try
            $(esc(code))
        finally
            release(temp)
        end
    end
end

function _wrap_fetch(w)
    acquire(w._exec.fetch_sem)
    w.last_fetch = now()
    try
        _fetch!(w, w._val)
    catch error
        @warn "Watcher error!" error
        false
    finally
        release(w._exec.fetch_sem)
    end
end
function _schedule_fetch(w, timeout, threads)
    fetcher_task = threads ? (@spawn _wrap_fetch(w)) : (@async _wrap_fetch(w))
    @async begin
        sleep(timeout)
        safenotify(fetcher_task.donenotify)
    end
    safewait(fetcher_task.donenotify)
    if istaskdone(fetcher_task) && fetch(fetcher_task)
        w.attempts = 0
        w.has.process && _process!(w, w._val)
        w.has.flush && flush!(w; sync=false)
    else
        w.attempts += 1
    end
end

function _timer!(w)
    w._timer = Timer(
        # NOTE: the callback for the timer requires 1 arg (the timer itself)
        (_) -> _schedule_fetch(w, w.interval.timeout, w._exec.threads),
        0;
        interval=convert(Second, w.interval.fetch).value,
    )
end

BufferEntry(T) = NamedTuple{(:time, :value),Tuple{DateTime,T}}
const HasFunction = NamedTuple{(:load, :process, :flush),NTuple{3,Bool}}
const Interval = NamedTuple{(:timeout, :fetch, :flush),NTuple{3,Millisecond}}
const Exec = NamedTuple{(:threads, :fetch_sem, :buffer_sem),Tuple{Bool,Semaphore,Semaphore}}
const Capacity = NamedTuple{(:buffer, :view),Tuple{Int,Int}}

@kwdef mutable struct Watcher19{T}
    const buffer::CircularBuffer{BufferEntry(T)}
    const name::String
    const has::HasFunction
    const interval::Interval
    const capacity::Capacity
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
 - `threads`: flag to enable to execute fetching in a separate thread.
 - `attempts`: In cause of fetching failure, tracks how many consecutive fails have occurred. It resets after a successful fetch operation.
 - `last_fetch`: the most recent time a fetch operation failed.
 - `last_flush`: the most recent time the flush function was called.
 - `_timer`: A [Timer](https://docs.julialang.org/en/v1/base/base/#Base.Timer), handles calling the function that fetches the data.
 """
Watcher = Watcher19

@doc """ Instantiate a watcher.

- `T`: The type of the underlying `CircularBuffer`
- `len`: length of the circular buffer.

!!! warning "asyncio vs threads"
    Both `_fetch!` and `_flush!` callbacks assume non-blocking asyncio like behaviour. If instead your functions require \
    high computation, pass `threads=true`, you will have to ensure thread safety.
"""
function watcher(
    T::Type,
    name;
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
    @debug "new watcher: $name"
    w = Watcher19{T}(;
        buffer=CircularBuffer{BufferEntry(T)}(buffer_capacity),
        name=String(name),
        has=HasFunction((load, process, flush)),
        interval=Interval((fetch_timeout, fetch_interval, flush_interval)),
        capacity=Capacity((buffer_capacity, view_capacity)),
        _exec=Exec((threads, Semaphore(1), Semaphore(1))),
        _val=Val(Symbol(name)),
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
    _timer!(w)
    @debug "watcher $name initialized!"
    w
end

@doc "Helper function to push a vector of values to the watcher buffer."
function pushstart!(w::Watcher, vec)
    isempty(vec) && return nothing
    time = now()
    start_offset = min(w.buffer.capacity, size(vec, 1))
    pushval(x) = push!(w.buffer, (; time, value=x.value))
    foreach(pushval, @view(vec[(end - start_offset + 1):end]))
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
    save_data(zilmdb(), key, buf; serialize=_isserialized(w), overwrite=true, reset)
end
default_flusher(w::Watcher) = default_flusher(w, w.name)
@doc "Load function for watcher data, loads from the default `DATA_PATH` \
located lmdb instance using serialization."
function default_loader(w::Watcher, key)
    begin
        get!(w.attrs, :loaded, false) && return nothing
        v = load_data(zilmdb(), key; serialized=_isserialized(w))
        !isnothing(v) && pushstart!(w, v)
        w.has.process && _process!(w, w._val)
        w.attrs[:loaded] = true
    end
end
default_loader(w::Watcher) = default_loader(w, w.name)

@doc "Processes the values of a watcher buffer into a dataframe.
To be used with: `default_init` and `default_get`
"
function default_process(w::Watcher, appendby::Function)
    isempty(w.buffer) && return nothing
    if w.attrs[:last_processed] == DateTime(0)
        appendby(w.attrs[:view], w.buffer, w.capacity.view)
    else
        idx = searchsortedfirst(
            w.buffer, w.attrs[:last_processed]; lt=(x, y) -> isless(x.time, y)
        )
        let range = (idx + 1):lastindex(w.buffer)
            length(range) > 0 &&
                appendby(w.attrs[:view], @view(w.buffer[range]), w.capacity.view)
        end
    end
    w.attrs[:last_processed] = w.buffer[end].time
end
function default_init(w::Watcher, dataview=DataFrame())
    w.attrs[:view] = dataview
    w.attrs[:last_processed] = DateTime(0)
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
        deleteat!(w.buffer, (from_idx + 1):lastindex(w.buffer, 1))
    else
        from_idx = searchsortedfirst(w.buffer, (; time=from); by=x -> x.time)
        to_idx = searchsortedlast(w.buffer, (; time=to); by=x -> x.time)
        deleteat!(w.buffer, (from_idx + 1):to_idx)
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
        t = @async @acquire w._exec.buffer_sem begin
            w.last_flush = time_now
            _flush!(w, w._val)
        end
    end
    sync && wait(t)
    nothing
end
@doc "Fetches a new value from the watcher ignoring the timer. If `reset` is `true` the timer is reset and
polling will resume after the watcher `interval`."
function fetch!(w::Watcher; reset=false)
    try
        if reset
            _schedule_fetch(w, w.interval.timeout, w._exec.threads)
            close(w._timer)
            _timer!(w)
        else
            _schedule_fetch(w, w.interval.timeout, w._exec.threads)
        end
    catch e
        @error e
    finally
        return last(w.buffer).value
    end
end
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
Base.close(w::Watcher) = @async begin
    isnothing(w._timer) || Base.close(w._timer)
    flush!(w)
    nothing
end
Base.empty!(w::Watcher) = empty!(w.buffer)
Base.getproperty(w::Watcher, p::Symbol) = begin
    if p == :view
        Base.get(w)
    else
        getfield(w, p)
    end
end

function Base.display(w::Watcher)
    out = IOBuffer()
    try
        tps = "$(typeof(w))"
        write(out, "$(length(w.buffer))-element ")
        if length(tps) > 80
            write(out, @view(tps[begin:40]))
            write(out, "...")
            write(out, @view(tps[(end - 40):end]))
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
        write(out, "$(w.last_fetch)")
        write(out, "\nFlushed: ")
        write(out, "$(w.last_flush)")
        Base.println(String(take!(out)))
    finally
        Base.close(out)
    end
end

export Watcher, watcher, isstale, default_loader, default_flusher
export default_process, default_init, default_get
export pushnew!, pushstart!

include("apis/coinmarketcap.jl")
include("apis/coingecko.jl")
include("apis/coinpaprika.jl")
include("impls/impls.jl")

end
