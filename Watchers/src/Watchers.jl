@doc "Watchers are data feeds, that keep track of stale data."
module Watchers
using Python
using TimeTicks
using DataStructures
using DataStructures: CircularBuffer
using Lang: Option
using Base.Threads: @spawn

safenotify(cond::Condition) = begin
    lock(cond)
    notify(cond)
    unlock(cond)
end
safewait(cond::Condition) = begin
    lock(cond)
    wait(cond)
    unlock(cond)
end

@kwdef mutable struct Watcher3{T}
    const data::CircularBuffer{Pair{DateTime,T}}
    const timeout::Millisecond
    const interval::Millisecond
    const _fetcher_sem::Base.Semaphore
    const _buffer_sem::Base.Semaphore
    timer::Option{Timer} = nothing
    attempts::Int = 0
    last_try::DateTime = DateTime(0)
    _flush_counter::Int = 0
end
@doc """ Watchers manage data, they pull from somewhere, keep a cache in memory, and optionally flush periodically to persistent storage.

 - `data`: A [CircularBuffer](https://juliacollections.github.io/DataStructures.jl/latest/circ_buffer/) of default length `1000` of the watcher type parameter.
 - `timer`: A [Timer](https://docs.julialang.org/en/v1/base/base/#Base.Timer), handles calling the function that fetches the data.
 - `timeout`: How much time to wait for the fetcher function.
 - `interval`: the `Period` with which the `fetcher` function will be called.
 - `attempts`: In cause of fetcher failure, tracks how many consecutive fails have occurred. It resets after a successful fetch operation.
 - `last_try`: the last time a fetch operation failed.
 """
Watcher = Watcher3

@doc """ Instantiate a watcher.

- `T`: The type of the underlying `CircularBuffer`
- `len`: length of the circular buffer.
- `fetcher`: The _input_ function that fetches data from somewhere, with signature `() -> T`.
- `flusher`: Optional function that is called once every `len` successful updates, `(AbstractVector) -> ()`

!!! warning "asyncio vs threads"
    Both `fetcher` and `flusher` callbacks assume non-blocking asyncio like behaviour. If instead your functions require \
    high computation, pass `threads=true`, you will have to ensure thread safety.
!!! warning
    If using flushers, do not modify the input data (argument of the flusher callback), always make a copy.
"""
function Watcher3(
    T::Type,
    fetcher,
    flusher=nothing;
    threads=false,
    len=1000,
    interval=Second(30),
    timeout=Second(5),
)
    begin
        mets = methods(fetcher)
        @assert length(mets) > 0 && length(mets[1].sig.parameters) == 1 "Function should have no arguments."
    end
    w = Watcher3{T}(CircularBuffer{T}(len); timeout, interval)
    finalizer(close, w)
    wrapped_fetcher() = begin
        try
            v = fetcher() # local bind, such that `now` is called after the event
            push!(w.data, (now(), v))
            true
        catch error
            @warn "Watcher error!" error
            false
        end
    end
    # NOTE: the callback for the timer requires 1 arg (the timer itself)
    function with_timeout(_)
        begin
            fetcher_task = threads ? (@spawn wrapped_fetcher()) : (@async wrapped_fetcher())
            @async begin
                sleep(timeout)
                safenotify(fetcher_task.donenotify)
            end
            safewait(fetcher_task.donenotify)
            if istaskdone(fetcher_task) && fetch(fetcher_task)
                w.attempts = 0
                w._flush_counter += 1
                if !isnothing(flusher) && w._flush_counter == length(w.data)
                    w._flush_counter = 0
                    flusher(w.data)
                end
            else
                w.attempts += 1
                w.last_try = now()
            end
        end
    end
    w.timer = Timer(with_timeout, 0; interval)
    w
end

@doc "True if last available data entry is older than `now() + interval + timeout`."
function isstale(w::Watcher)
    w.attempts > 0 || last(w.data).first < now() - w.interval - w.timeout
end
Base.last(w::Watcher) = last(w.data)
Base.length(w::Watcher) = length(w.data)
close(w::Watcher) = isnothing(w.timer) || close(w.timer)

export Watcher, isstale

include("apis/coinmarketcap.jl")
include("apis/coingecko.jl")
include("apis/coinpaprika.jl")
include("impl.jl")

end
