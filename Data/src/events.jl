@doc """EventTrace structure for managing event data.

$(FIELDS)

Represents a collection of events with caching capabilities. It is designed to efficiently handle large datasets by caching event data in memory. The structure includes a ZarrInstance for data storage, a ZArray for data access, a cache for temporary storage, a frequency for event timing, and an index for the next event.

"""
mutable struct EventTrace{I<:ZarrInstance,Z<:ZArray}
    const _zi::I
    const _arr::Z
    const _cache::Vector{Vector{UInt8}}
    const freq::Period
    last_flush::DateTime
    function EventTrace(name; freq=Second(1), path=nothing, zi=nothing)
        zi_args = isnothing(path) ? () : (path,)
        zi = @something zi ZarrInstance(zi_args...)
        arr = load_data(zi, string(name); serialized=true, as_z=true)[1]
        cache = Vector{UInt8}[]
        new{typeof(zi),typeof(arr)}(zi, arr, cache, freq, DateTime(0))
    end
end

function show(name; path=nothing, zi=nothing)
    zi_args = isnothing(path) ? () : (path,)
    zi = @something zi ZarrInstance(zi_args...)
    arr = load_data(zi, name; serialized=true, as_z=true)[1]
    new{typeof(zi),typeof(arr)}(zi, arr)
end

@nospecialize
function Base.print(io::IO, et::EventTrace)
    println(io, "EventTrace")
    println(io, "name: ", et._arr.path)
    n = size(et._arr, 1)
    println(io, "events: ", n)
    if size(et._arr, 1) > 0
        start = todata(et._arr[begin, :][1])
        stop = todata(et._arr[end, :][1])
        println(io, "period: ", start, " .. ", stop)
    else
        println(io, "period: ", nothing)
    end
    println(
        io,
        "last event: ",
        if n == 0
            nothing
        else
            todata(et._arr[end, :][2])
        end,
    )
end

Base.display(s::EventTrace; kwargs...) = print(s)
Base.show(out::IO, ::MIME"text/plain", s::EventTrace; kwargs...) = print(out, s; kwargs...)
Base.show(out::IO, s::EventTrace; kwargs...) = print(out, ":", nameof(s))

@specialize

function Base.push!(et::EventTrace, v; event_date=now(), this_date=now(), sync=false)
    this_v = tobytes.([event_date, v])
    push!(et._cache, this_v)
    if sync || this_date - et.last_flush > et.freq
        append!(et._arr, splice!(et._cache, eachindex(et._cache)))
        et.last_flush = this_date
    end
    v
end

Base.empty!(et::EventTrace) = empty!(et._arr)
Base.length(et::EventTrace) = size(et._arr, 1)


