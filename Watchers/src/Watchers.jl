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

BufferEntry(T) = NamedTuple{(:time, :value),Tuple{DateTime,T}}

@kwdef mutable struct Watcher8{T}
    const buffer::CircularBuffer{BufferEntry(T)}
    const name::SubString
    const timeout::Millisecond
    const interval::Millisecond
    const flush_interval::Millisecond
    const _fetcher_sem::Semaphore
    const _buffer_sem::Semaphore
    _fetch_func::Function = (_) -> ()
    _flush_func::Function = (_) -> nothing
    _start_func::Function = (_) -> T[]
    timer::Option{Timer} = nothing # maybe this should be private
    attempts::Int = 0
    last_try::DateTime = DateTime(0)
    last_flush::DateTime = DateTime(0)
end
@doc """ Watchers manage data, they pull from somewhere, keep a cache in memory, and optionally flush periodically to persistent storage.

 - `buffer`: A [CircularBuffer](https://juliacollections.github.io/DataStructures.jl/latest/circ_buffer/) of default length `1000` of the watcher type parameter.
 - `name`: Give it a name for better logging.
 - `timer`: A [Timer](https://docs.julialang.org/en/v1/base/base/#Base.Timer), handles calling the function that fetches the data.
 - `timeout`: How much time to wait for the fetcher function.
 - `interval`: the `Period` with which the `fetcher` function will be called.
 - `flush_interval`: the `Period` with which the `flusher` function will be called.
 - `attempts`: In cause of fetcher failure, tracks how many consecutive fails have occurred. It resets after a successful fetch operation.
 - `last_try`: the most recent time a fetch operation failed.
 - `last_flush`: the most recent time the flush function was called.
 """
Watcher = Watcher8

@doc """ Instantiate a watcher.

- `T`: The type of the underlying `CircularBuffer`
- `len`: length of the circular buffer.
- `fetcher`: The _input_ function that fetches data from somewhere, with signature `() -> T`.
- `flusher`: Optional function that is called once every `len` successful updates, `(AbstractVector) -> ()`
- `starter`: Optional function that is called on watcher startup to prefill the buffer with previous (most recent) data, `(AbstractString) -> AbstractVector`

!!! warning "asyncio vs threads"
    Both `fetcher` and `flusher` callbacks assume non-blocking asyncio like behaviour. If instead your functions require \
    high computation, pass `threads=true`, you will have to ensure thread safety.
!!! warning
    If using flushers, do not modify the input data (argument of the flusher callback), always make a copy.
"""
function watcher(
    T::Type,
    name::AbstractString,
    fetcher::Function;
    flusher::Union{Bool,Function}=false,
    starter::Union{Bool,Function}=true,
    threads=false,
    len=1000,
    interval=Second(30),
    flush_interval=Second(360),
    timeout=Second(5),
)
    local w
    let mets = methods(fetcher)
        @assert length(mets) > 0 && length(mets[1].sig.parameters) == 1 "Function should have no arguments."
    end
    let buffer = CircularBuffer{BufferEntry(T)}(len)
        w = Watcher8{T}(;
            name=SubString(name),
            buffer,
            timeout,
            interval,
            flush_interval,
            _fetcher_sem=Semaphore(1),
            _buffer_sem=Semaphore(1),
        )
        w = finalizer(close, w)
    end
    let start_buf = (starter isa Function ? starter : default_starter)(w), time = now()
        start_offset = min(len, size(start_buf, 1)) + 1
        foreach(
            x -> push!(w.buffer, (; time, value=x)),
            @view(start_buf[(end - start_offset):end])
        )
    end
    function wrapped_fetcher()
        local value
        acquire(w._fetcher_sem)
        time = now()
        try
            value = fetcher() # local bind, such that `now` is called after the event
            value != w.buffer[end].value && push!(w.buffer, (; time, value))
            true
        catch error
            if error isa BoundsError && isempty(w.buffer)
                push!(w.buffer, (; time, value))
                true
            else
                @warn "Watcher error!" error
                false
            end
        finally
            release(w._fetcher_sem)
        end
    end
    w._flush_func = if flusher isa Function
        @assert applicable(flusher, w) "Incompatible flusher function. (It must accept a `Watcher`)"
        flusher
    elseif flusher
        (w) -> default_flusher(w)
    else
        (_) -> nothing
    end
    # NOTE: the callback for the timer requires 1 arg (the timer itself)
    w._fetch_func =
        (_) -> begin
            fetcher_task = threads ? (@spawn wrapped_fetcher()) : (@async wrapped_fetcher())
            @async begin
                sleep(timeout)
                safenotify(fetcher_task.donenotify)
            end
            safewait(fetcher_task.donenotify)
            if istaskdone(fetcher_task) && fetch(fetcher_task)
                w.attempts = 0
                let time_now = now()
                    time_now - w.last_flush > w.flush_interval && _call_flush(w, time_now)
                end
            else
                w.attempts += 1
                w.last_try = now()
            end
        end
    w.timer = Timer(w._fetch_func, 0; interval=interval.value)
    w.last_flush = now()
    w
end

_call_flush(w::Watcher, time=now()) = @async @acquire w._buffer_sem begin
    w.last_flush = time
    w._flush_func(w.buffer)
end
@doc "Force flush watcher."
flush!(w::Watcher) = w._flush_func(w)
@doc "Save function for watcher data, saves to the default `DATA_PATH` \
located lmdb instance using serialization."
function default_flusher(w::Watcher)
    save_data(zilmdb(), w.name, w.buffer; serialize=true)
end
default_starter(w::Watcher) = begin
    load_data(zilmdb(), w.name; serialized=true)
end

@doc "Fetches a new value from the watcher ignoring the timer. If `reset` is `true` the timer is reset and
polling will resume after the watcher `interval`."
function fetch!(w::Watcher; reset=false)
    try
        if reset
            w._fetch_func()
            close(w.timer)
            w.timer = Timer(w._fetch_func, w.interval.value; interval=w.interval.value)
        else
            w._fetch_func(w.timer)
        end
    catch e
        @error e
    finally
        return last(w.buffer).value
    end
end

@doc "True if last available data entry is older than `now() + interval + timeout`."
function isstale(w::Watcher)
    w.attempts > 0 || last(w.buffer).time < now() - w.interval - w.timeout
end
Base.last(w::Watcher) = last(w.buffer)
Base.length(w::Watcher) = length(w.buffer)
Base.close(w::Watcher) = begin
    isnothing(w.timer) || Base.close(w.timer)
    flush!(w)
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
        write(out, "\nFetch: ")
        write(out, "$(compact(w.interval))")
        write(out, "\nFlush: ")
        write(out, "$(compact(w.flush_interval))")
        write(out, "\nTimeout: ")
        write(out, "$(compact(w.timeout))")
        write(out, "\nFlushed: ")
        write(out, "$(w.last_flush)")
        Base.println(String(take!(out)))
    finally
        Base.close(out)
    end
end

export Watcher, watcher, isstale

include("apis/coinmarketcap.jl")
include("apis/coingecko.jl")
include("apis/coinpaprika.jl")
include("impls/impls.jl")

end
