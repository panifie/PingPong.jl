import Fetch.Exchanges.ExchangeTypes: exchange, exchangeid
import .Misc: start!, stop!, load!

_timer(w) = getfield(w, :_timer)
_exec(w) = getfield(w, :_exec)
_fetch_lock(w) = getfield(_exec(w), :fetch_lock)
_buffer_lock(w) = getfield(_exec(w), :buffer_lock)
_errors(w) = getfield(_exec(w), :errors)
_val(w) = getfield(w, :_val)

exchange(w::Watcher) = attr(w, :exc, nothing)
exchangeid(w::Watcher) =
    let e = exchange(w)
        isnothing(e) ? nothing : nameof(e)
    end

@doc "Delete watcher data from storage backend within the date range specified."
function Base.deleteat!(w::Watcher, range::DateTuple)
    _deleteat!(w, _val(w); from=range.start, to=range.stop)
end

@doc "Flush the watcher. If wait is `true`, block until flush completes."
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
    @logerror w begin
        _process!(w, _val(w), args...; kwargs...)
        safenotify(w.beacon.process)
    end
end
load!(w::Watcher, args...; kwargs...) = _load!(w, _val(w), args...; kwargs...)
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
Base.last(w::Watcher) = last(w.buffer)
Base.length(w::Watcher) = length(w.buffer)
function Base.close(w::Watcher; doflush=true)
    # @lock w begin
    l = w._exec.fetch_lock
    if trylock(l)
        try
            isstopped(w) || stop!(w)
            doflush && flush!(w)
            if haskey(WATCHERS, w.name)
                attr(WATCHERS[w.name], :started, DateTime(0)) ==
                attr(w, :started, DateTime(0)) && delete!(WATCHERS, w.name)
            end
            nothing
        finally
            unlock(l)
        end
    else
        w._stop = true
    end
end
Base.empty!(w::Watcher) = empty!(buffer(w))
Base.getproperty(w::Watcher, p::Symbol) = begin
    if p == :view
        Base.get(w)
    else
        getfield(w, p)
    end
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
Base.islocked(w::Watcher) = islocked(_fetch_lock(w))
Base.islocked(w::Watcher, ::Val{:buffer}) = islocked(_buffer_lock(w))
Base.lock(f, w::Watcher) = lock(f, _fetch_lock(w))
Base.lock(f, w::Watcher, ::Val{:buffer}) = lock(f, _buffer_lock(w))
Base.lock(w::Watcher) = lock(_fetch_lock(w))
Base.lock(w::Watcher, ::Val{:buffer}) = lock(_buffer_lock(w))
Base.unlock(w::Watcher) = unlock(_fetch_lock(w))
Base.unlock(w::Watcher, ::Val{:buffer}) = unlock(_buffer_lock(w))

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
