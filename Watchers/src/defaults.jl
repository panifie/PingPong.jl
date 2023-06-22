@doc "Helper function to push a vector of values to the watcher buffer."
function pushstart!(w::Watcher, vec)
    isempty(vec) && return nothing
    time = now()
    start_offset = min(w.buffer.capacity, size(vec, 1))
    pushval(x) = push!(w.buffer, (; time, value=x.value))
    foreach(pushval, @view(vec[(end - start_offset + 1):end]))
end

@doc "Helper function to push a new value to the watcher buffer if it is different from the last one."
function pushnew!(w::Watcher, value, time=nothing)
    # NOTE: use object inequality to avoid non determinsm
    if !isnothing(value) && (isempty(w.buffer) || value != w.buffer[end].value)
        push!(w.buffer, (time=@something(time, now()), value))
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
function default_init(w::Watcher, dataview=DataFrame(), serialized=true)
    w.attrs[:view] = dataview
    w.attrs[:last_processed] = nothing
    w.attrs[:checks] = Val(:off)
    w.attrs[:serialized] = serialized
    haskey(w.attrs[:logfile]) && write(w.attrs[:logfile], "")
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
        deleteat!(w.buffer, (from_idx + 1):lastindex(w.buffer, 1))
    else
        from_idx = searchsortedfirst(w.buffer, (; time=from); by=x -> x.time)
        to_idx = searchsortedlast(w.buffer, (; time=to); by=x -> x.time)
        deleteat!(w.buffer, (from_idx + 1):to_idx)
    end
end
