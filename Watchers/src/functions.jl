import Fetch.Exchanges.ExchangeTypes: exchange, exchangeid
import .Misc: start!, stop!, load!, isrunning
import .Data.DFUtils: lastdate
using .Lang: @ifdebug, @caller

baremodule LogWatchLocks end
baremodule TraceWatchLocks end

const _LOCK_TRACE = []

_timer(w) = getfield(w, :_timer)
_exec(w) = getfield(w, :_exec)
_fetch_lock(w) = getfield(_exec(w), :fetch_lock)
_buffer_lock(w) = getfield(_exec(w), :buffer_lock)
_errors(w) = getfield(_exec(w), :errors)
_val(w) = getfield(w, :_val)
watcher_tasks(w) = begin
    a = w.attrs
    if get(a, :iswatch, false) && haskey(a, :handler)
        w.handler.process_tasks
    else
        @lget! a :process_tasks Task[]
    end
end

@doc "Get the exchange associated with the watcher."
exchange(w::Watcher) = attr(w, :exc, nothing)
@doc "Get the name of the exchange associated with the watcher."
exchangeid(w::Watcher) =
    let e = exchange(w)
        isnothing(e) ? nothing : nameof(e)
    end

@doc "Delete watcher data from storage backend within the date range specified."
function Base.deleteat!(w::Watcher, range::DateTuple)
    _deleteat!(w, _val(w); from=range.start, to=range.stop)
end

@doc """ Executes the flush function of the watcher (defaults to [`default_flusher`](@ref)).

$(TYPEDSIGNATURES)

The function takes a watcher as an argument, along with optional force and sync arguments. If force is true or the time since the last flush is greater than the flush interval, it schedules a flush operation. If sync is true, it waits for the flush operation to complete.
"""
function flush!(w::Watcher; force=true, sync=false)
    time_now = now()
    if force || time_now - w.last_flush > w.interval.flush
        t = @async begin
            result = @lock w._exec.buffer_lock begin
                w.last_flush = time_now
                _flush!(w, _val(w))
                safenotify(w.beacon.flush)
            end
            ifelse(result isa Exception, logerror(w, result), result)
        end
    end
    sync && wait(t)
    nothing
end
@doc """ Fetches a new value from the watcher ignoring the timer.

$(TYPEDSIGNATURES)

The function takes a watcher as an argument, along with optional reset and kwargs arguments. It schedules a fetch operation, and if reset is true, it resets the timer. The function returns the last value in the watcher buffer or nothing if the buffer is empty.
"""
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

@doc "Executes the watcher `_process!` function (defaults to [`default_process`](@ref))."
function process!(w::Watcher, args...; kwargs...)
    @logerror w begin
        @lock _buffer_lock(w) begin
            _process!(w, _val(w), args...; kwargs...)
            safenotify(w.beacon.process)
        end
    end
end
@doc "Executes the watcher `_load!` function (defaults to [`default_loader`](@ref))."
load!(w::Watcher, args...; kwargs...) = _load!(w, _val(w), args...; kwargs...)
@doc "Executes the watcher `_init!` function (defaults to [`default_init`](@ref))."
init!(w::Watcher, args...; kwargs...) = _init!(w, _val(w), args...; kwargs...)
@doc "Add `v` to the things the watcher is fetching."
function Base.push!(w::Watcher, v, args...; kwargs...)
    _push!(w, _val(w), v, args...; kwargs...)
end
@doc "Remove `v` from the things the watcher is fetching."
function Base.pop!(w::Watcher, v, args...; kwargs...)
    _pop!(w, _val(w), v, args...; kwargs...)
end

@doc "True if last available data entry is older than `now() + fetch_interval + fetch_timeout`."
function isstale(w::Watcher)
    w.attempts > 0 || w.last_fetch < now() - w.interval.fetch - w.interval.timeout
end
@doc "The last available data entry."
Base.last(w::Watcher) = last(w.buffer)
@doc "True if the watcher buffer is empty."
Base.isempty(w::Watcher) = isempty(w.buffer)
@doc "The length of the watcher buffer."
Base.length(w::Watcher) = length(w.buffer)
@doc "The date of the last update fetched by the watcher."
function lastdate(w::Watcher)
    buf = buffer(w)
    if isempty(buf)
        typemin(DateTime)
    else
        last(buf).time
    end
end
@doc """ Stops the watcher and optionally flushes the data.

$(TYPEDSIGNATURES)

The function takes a watcher and an optional doflush argument. If the watcher is not stopped, it stops the watcher. If doflush is true, it flushes the watcher data.
"""
function Base.close(w::Watcher; doflush=true)
    lf = trylock(w._exec.fetch_lock)
    lb = trylock(w._exec.buffer_lock)
    try
        if !isstopped(w)
            stop!(w)
        end
        doflush && flush!(w)
        global_w = get(WATCHERS, w.name, missing)
        if global_w === w
            delete!(WATCHERS, w.name)
        end
        nothing
    catch
    finally
        if lf
            unlock(w._exec.fetch_lock)
        end
        if lb
            unlock(w._exec.buffer_lock)
        end
    end
end
@doc "Empty the watcher buffer."
Base.empty!(w::Watcher) = begin
    empty!(buffer(w))
    view = attr(w, :view, nothing)
    try
        empty!(view)
    catch e
        if !(e isa MethodError)
            rethrow(w)
        end
    end
end
Base.getproperty(w::Watcher, p::Symbol) = begin
    if hasfield(Watcher, p)
        getfield(w, p)
    else
        attrs = getfield(w, :attrs)
        getindex(attrs, p)
    end
end
Base.getproperty(w::Watcher, p::String) = begin
    attrs = getfield(w, :attrs)
    getindex(attrs, :view)[p]
end
buffer(w::Watcher) = getfield(w, :buffer)
Base.getindex(w::Watcher, i::Symbol) = attr(w, i)
Base.setindex!(w::Watcher, v, i::Symbol) = setattr!(w, v, i)
Base.first(w::Watcher) = first(attrs(w))
Base.pairs(w::Watcher) = pairs(attrs(w))
Base.values(w::Watcher) = values(attrs(w))
Base.keys(w::Watcher) = keys(attrs(w))
Base.eltype(w::Watcher) = eltype(buffer(w).parameters[2].parameters[2])
Base.getindex(w::Watcher, i) = getindex(attr(w, :view), i)

@doc "Stops the watcher timer."
stop!(w::Watcher) = begin
    @assert isstarted(w) "Tried to stop an already stopped watcher."
    Base.close(w._timer)
    safenotify(w.beacon.fetch)
    safenotify(w.beacon.process)
    safenotify(w.beacon.flush)
    _stop!(w, _val(w))
    w._stop = true
    nothing
end
@doc "Resets the watcher timer."
start!(w::Watcher) = begin
    @assert isstopped(w) "Tried to start an already started watcher."
    empty!(_errors(w))
    w[:started] = now()
    _start!(w, _val(w))
    _timer!(w)
    w._stop = false
    nothing
end
@doc "True if timer is not running."
isstopped(w::Watcher) =
    let t = _timer(w)
        isnothing(t) || !isopen(t)
    end
@doc "True if timer is running."
isstarted(w::Watcher) =
    let t = _timer(w)
        !isnothing(t) && isopen(t)
    end
isrunning(w::Watcher) = isstarted(w)

@doc "True if watcher if the fetch lock locked."
Base.islocked(w::Watcher) = islocked(_fetch_lock(w))
@doc "True if the buffer lock is locked."
Base.islocked(w::Watcher, ::Val{:buffer}) = islocked(_buffer_lock(w))
@doc "Lock the fetch lock and execute `f`."
Base.lock(f, w::Watcher) = begin
    @debug "watchers: locking fetch" _module = LogWatchLocks w = w.name f = @caller
    lock(f, _fetch_lock(w))
    @debug "watchers: unlocked fetch" _module = LogWatchLocks w = w.name f = @caller
end
@doc "Lock the buffer lock and execute `f`."
Base.lock(f, w::Watcher, ::Val{:buffer}) = begin
    @debug "watchers: locking buffer" _module = LogWatchLocks w = w.name f = @caller
    lock(f, _buffer_lock(w))
    @debug "watchers: unlocked buffer" _module = LogWatchLocks w = w.name f = @caller
end
@doc "Lock the fetch lock."
Base.lock(w::Watcher) = begin
    @debug "watchers: locking fetch" _module = LogWatchLocks w = w.name f = @caller
    lock(_fetch_lock(w))
    @debug "watchers: locked fetch" _module = LogWatchLocks w = w.name f = @caller
    @ifdebug TraceWatchLocks push!(_LOCK_TRACE, stacktrace())
end
@doc "Lock the buffer lock."
Base.lock(w::Watcher, ::Val{:buffer}) = begin
    @debug "watchers: locking buffer" _module = LogWatchLocks w = w.name f = @caller
    lock(_buffer_lock(w))
    @debug "watchers: locked buffer" _module = LogWatchLocks w = w.name f = @caller
    @ifdebug TraceWatchLocks push!(_LOCK_TRACE, stacktrace())
end
@doc "Unlock the fetch lock."
Base.unlock(w::Watcher) = begin
    unlock(_fetch_lock(w))
    @debug "watchers: unlocked fetch" _module = LogWatchLocks w = w.name f = @caller
end
@doc "Unlock the buffer lock."
Base.unlock(w::Watcher, ::Val{:buffer}) = begin
    unlock(_buffer_lock(w))
    @debug "watchers: unlocked buffer" _module = LogWatchLocks w = w.name f = @caller
end
function Base.wait(w::Watcher, b=:fetch)
    if isstopped(w)
        false
    else
        safewait(getproperty(w.beacon, b))
        true
    end
end

function Base.wait(w::Watcher, timeout::Period, b=:fetch)
    if isstopped(w)
        false
    else
        slept = waitforcond(getproperty(w.beacon, b), timeout)
        slept < Millisecond(timeout).value
    end
end

function Base.show(out::IO, w::Watcher)
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
    write(out, "$(w.last_fetch) busy: $(islocked(w._exec.fetch_lock))")
    write(out, "\nFlushed: ")
    write(out, "$(w.last_flush)")
    write(out, "\nActive: ")
    write(out, "$(isstarted(w))")
    write(out, "\nAttempts: ")
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
Base.get(w::Watcher, k, def) = attr(w, k, def)

function jsontodict(json; to=Dict{String,Any})
    to(convert(keytype(to), k) => convert(valtype(to), v) for (k, v) in json)
end
