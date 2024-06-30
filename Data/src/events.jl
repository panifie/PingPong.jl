@doc """EventTrace structure for managing event data.

$(FIELDS)

Represents a collection of events with caching capabilities. It is designed to efficiently handle large datasets by caching event data in memory. The structure includes a ZarrInstance for data storage, a ZArray for data access, a cache for temporary storage, a frequency for event timing, and an index for the next event.

"""
mutable struct EventTrace{I<:ZarrInstance,Z<:ZArray}
    const lock::ReentrantLock
    const _buf::IOBuffer
    const _zi::I
    const _arr::Z
    const _cache::Vector{Vector{Vector{UInt8}}}
    const freq::Period
    last_flush::DateTime
    function EventTrace(name; freq=Second(1), path=nothing, zi=nothing)
        zi_args = isnothing(path) ? () : (path,)
        zi = @something zi ZarrInstance(zi_args...)
        arr = load_data(zi, string(name); serialized=true, as_z=true)[1]
        cache = Matrix{Vector{UInt8}}[]
        new{typeof(zi),typeof(arr)}(
            ReentrantLock(), IOBuffer(), zi, arr, cache, freq, DateTime(0)
        )
    end
end

eventtrace(args...; kwargs...) = EventTrace(args...; kwargs...)

@nospecialize
function Base.print(io::IO, et::EventTrace)
    println(io, "EventTrace")
    println(io, "name: ", et._arr.path)
    n = size(et._arr, 1)
    println(io, "events: ", n)
    if size(et._arr, 1) > 0
        start = todata(et._arr[begin, 1])
        stop = todata(et._arr[end, 1])
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
            last_v = todata(et._arr[end, 2])
            if hasfield(typeof(last_v), :tag)
                last_v.tag
            end
        end,
    )
end

Base.display(s::EventTrace; kwargs...) = print(s)
Base.show(out::IO, ::MIME"text/plain", s::EventTrace; kwargs...) = print(out, s; kwargs...)
Base.show(out::IO, s::EventTrace; kwargs...) = print(out, ":", nameof(s))

@specialize

function Base.push!(et::EventTrace, v; event_date=now(), this_date=now(), sync=false)
    @lock et.lock begin
        this_v = tobytes.(et._buf, [event_date, v])
        push!(et._cache, this_v)
        if sync || this_date - et.last_flush > et.freq
            n_cached = size(et._cache, 1)
            if n_cached > 0
                this_size = size(et._arr, 1)
                resize!(et._arr, this_size + n_cached, 2)
                et._arr[(this_size + 1):end, :] .= permutedims(
                    hcat(splice!(et._cache, eachindex(et._cache))...)
                )
                et.last_flush = this_date
            end
        end
        v
    end
end

Base.empty!(et::EventTrace) = (empty!(et._arr); resize!(et._arr, 0, 2))
Base.length(et::EventTrace) = size(et._arr, 1)
Base.isempty(et::EventTrace) = isempty(et._arr)

function trace_tail(et::EventTrace, n=10; as_df=false)
    len = length(et)
    if iszero(len)
        return nothing
    end
    ans = @lock(et.lock, todata.(et._buf, et._arr[(end - min(len, n) + 1):end, :]))
    if as_df
        dates = DateTime[]
        tags = Symbol[]
        data = Any[]
        for v in eachrow(ans)
            ev = v[2]
            push!(dates, v[1])
            push!(tags, ev.tag)
            push!(data, ev)
        end
        DataFrame([dates, tags, data], [:date, :tag, :data]; copycols=false)
    else
        ans
    end
end
