@doc """ Pushes a vector of values to the watcher buffer.

$(TYPEDSIGNATURES)

The function takes a watcher and a vector as arguments. If the vector is empty, the function returns nothing. Otherwise, it calculates the minimum of the buffer capacity and the size of the vector, and pushes the values from the vector to the watcher buffer starting from the calculated offset.
"""
function pushstart!(w::Watcher, vec)
    isempty(vec) && return nothing
    time = now()
    start_offset = min(w.buffer.capacity, size(vec, 1))
    pushval(x) = push!(w.buffer, (; time, value=x.value))
    foreach(pushval, @view(vec[(end-start_offset+1):end]))
end

@doc """ Pushes a new value to the watcher buffer if it is different from the last one.

$(TYPEDSIGNATURES)

The function takes a watcher, a value, and an optional time as arguments. If the value is not `nothing` and it is different from the last value in the watcher buffer, the function pushes a new tuple containing the time and the value to the watcher buffer.
"""
function pushnew!(w::Watcher{T}, value, time=nothing) where {T}
    # NOTE: use object inequality to avoid non determinsm
    buf = buffer(w)
    @lock _buffer_lock(w) if !isnothing(value) && (isempty(buf) || Bool(value !== buf[end].value))
        # TODO: remove this check once DataStructures releases 1.0
        if value isa T || applicable(convert, T, value)
            v = (time=@something(time, now()), value)
            push!(buf, v)
        else
            @error "watchers: wrong type" expected = T got = typeof(value)
        end
    end
end

@doc """ Checks if the watcher data is serialized.

$(TYPEDSIGNATURES)

The function takes a watcher as an argument and returns a boolean indicating whether the watcher data is serialized or not.
"""
_isserialized(w::Watcher) = attr!(w, :serialized, false)

@doc """ Saves watcher data to the default `DATA_PATH` using serialization.

$(TYPEDSIGNATURES)

The function takes a watcher and a key as arguments, along with optional parameters for reset and buffer. If the buffer is empty, the function returns nothing. If the most recent time in the buffer is greater than the last flushed time, the function saves the recent slice of data to the `DATA_PATH` and updates the last flushed time.
"""
function default_flusher(w::Watcher, key; reset=false, buf=w.buffer)
    isempty(buf) && return nothing
    most_recent = last(buf)
    last_flushed = attr!(w, :last_flushed, (; time=DateTime(0)))
    if most_recent.time > last_flushed.time
        recent_slice = after(buf, last_flushed; by=x -> x.time)
        save_data(
            zinstance(),
            key,
            recent_slice;
            serialize=_isserialized(w),
            overwrite=true,
            reset,
        )
        setattr!(w, most_recent, :last_flushed)
    end
end
default_flusher(w::Watcher) = default_flusher(w, w.name)
@doc """ Loads watcher data from the default `DATA_PATH`.

$(TYPEDSIGNATURES)

The function takes a watcher and a key as arguments. If the watcher data is not loaded, the function returns nothing. Otherwise, it loads the data from the `DATA_PATH`, pushes it to the watcher buffer using `pushstart!`, processes the watcher data if necessary, and sets the `loaded` attribute of the watcher to `true`.
"""
function default_loader(w::Watcher, key)
    attr!(w, :loaded, false) && return nothing
    v = load_data(zinstance(), key; serialized=_isserialized(w))
    !isnothing(v) && pushstart!(w, v)
    w.has.process && process!(w)
    setattr!(w, true, :loaded)
end
default_loader(w::Watcher) = default_loader(w, w.name)

@doc """ Processes the values of a watcher buffer into a dataframe.

$(TYPEDSIGNATURES)

The function takes a watcher and an appendby function as arguments. If the buffer is empty, the function returns nothing. Otherwise, it checks if the last processed attribute of the watcher is `nothing`.
"""
function default_process(w::Watcher, appendby::Function)
    isempty(w.buffer) && return nothing
    last_p = attr(w, :last_processed)
    if isnothing(last_p)
        appendby(attr(w, :view), w.buffer, w.capacity.view)
    else
        range = rangeafter(w.buffer, last_p; by=x -> x.time)
        length(range) > 0 &&
            appendby(attr(w, :view), view(w.buffer, range), w.capacity.view)
    end
    setattr!(w, w.buffer[end], :last_processed)
end
@doc """ Returns the default view of the watcher data.

$(TYPEDSIGNATURES)

The function takes a watcher and an optional definition as arguments. If the default view attribute of the watcher is `nothing`, it returns the result of the definition function. Otherwise, it deletes the default view attribute from the watcher and returns it if it is a function or the result of the function if it is not.
"""
function default_view(w::Watcher, def::Union{Type,Function}=Data.empty_ohlcv)
    def_view = attr(w, :default_view, nothing)
    if isnothing(def_view)
        def()
    else
        delete!(w.attrs, :default_view)
        if def_view isa Function
            def_view()
        else
            def_view
        end
    end
end
@doc """ Initializes a watcher with default attributes.

$(TYPEDSIGNATURES)

The function takes a watcher and optional dataview and serialized arguments. It sets the view, last_processed, checks, and serialized attributes of the watcher. If a logfile attribute is present, it writes an empty string to the logfile.
"""
function default_init(w::Watcher, dataview=default_view(w, empty_ohlcv), serialized=true)
    a = attrs(w)
    a[:view] = dataview
    a[:last_processed] = nothing
    a[:checks] = Val(:off)
    a[:serialized] = serialized
end
@doc """ Returns the processed `view` of the watcher data.

$(TYPEDSIGNATURES)

The function takes a watcher as an argument and returns the `view` attribute of the watcher.
"""
default_get(w::Watcher, def) = get(w.attrs, :view, def)

_notimpl(sym, w) = throw(error("`$sym` Not Implemented for watcher `$(w.name)`"))
@doc "May run after a successful fetch operation, according to the `flush_interval`. It spawns a task."
_flush!(w::Watcher, ::Val) = default_flusher(w, w.key)
@doc "Called once on watcher creation, used to pre-fill the watcher buffer."
_load!(w::Watcher, ::Val) = default_loader(w, w.key)
@doc "Appends new data to the watcher buffer, returns `true` when new data is added, `false` otherwise."
_fetch!(w::Watcher, ::Val) = _notimpl(fetch!, w)
@doc "Processes the watcher data, called everytime the watcher fetches new data."
_process!(w::Watcher, ::Val) = default_process(w, Data.DFUtils.appendmax!)
@doc "Function to run on watcher initialization, it runs before `_load!`."
_init!(w::Watcher, ::Val) = default_init(w)

@doc "Returns the processed `view` of the watcher data."
_get(w::Watcher, ::Val, def=nothing) = default_get(w, def)
@doc "Returns the processed `view` of the watcher data. Accessible also as a `view` property of the watcher object."
Base.get(w::Watcher, def) = _get(w, _val(w), def)
@doc "If the watcher manager a group of things that it is fetching, `_push!` should add an element to it."
_push!(w::Watcher, ::Val) = _notimpl(push!, w)
@doc "Same as `_push!` but for removing elements."
_pop!(w::Watcher, ::Val) = _notimpl(pop!, w)
function _delete!(w::Watcher, ::Val)
    delete!(zinstance().group, attr!(w, :key, w.name))
    nothing
end
@doc "Executed before starting the timer."
_start!(_::Watcher, ::Val) = nothing
@doc "Executed after the timer has been stopped."
_stop!(_::Watcher, ::Val) = nothing
@doc "Deletes all watcher data from storage backend. Also empties the buffer."
function Base.delete!(w::Watcher)
    _delete!(w, _val(w))
    empty!(w.buffer)
end
@doc """ Deletes a range of data from the watcher buffer and storage backend.

$(TYPEDSIGNATURES)

The function takes a watcher as an argument, along with optional from and to arguments. It deletes the data from the storage backend and the watcher buffer within the specified range. If no range is specified, it deletes all data.
"""
function _deleteat!(w::Watcher, ::Val; from=nothing, to=nothing, kwargs...)
    k = attr!(w, :key, w.name)
    z = load_data(zinstance(), k; as_z=true)
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

@doc """ Imports the watcher interface functions.

This macro imports the watcher interface functions into the current scope. These functions are used to define the behavior of a watcher.
"""
macro watcher_interface!()
    quote
        import .Watchers:
            _fetch!,
            _load!,
            _flush!,
            _init!,
            _delete!,
            _deleteat!,
            _start!,
            _stop!,
            _process!,
            _push!,
            _pop!,
            _get
    end
end

export @watcher_interface!
