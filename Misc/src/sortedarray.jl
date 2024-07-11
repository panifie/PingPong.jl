import Serialization: serialize, deserialize, AbstractSerializer, serialize_type

_dosort!(arr::AbstractVector, args...; dims=1, kwargs...) = sort!(arr, args...; kwargs...)
_dosort!(arr, args...; kwargs...) = sort!(arr, args...; kwargs...)

struct SortedArray{T,N,A<:AbstractArray{T,N}} <: AbstractArray{T,N}
    arr::A
    opts::NamedTuple{(:dims, :rev, :by),Tuple{Int,Bool,Function}}
    function SortedArray(
        arr::A=Vector[]; dims=1, rev=false, by=identity
    ) where {A<:AbstractArray}
        new{eltype(A),ndims(A),A}(_dosort!(arr; dims, rev, by), (; dims, rev, by))
    end
end

function Base.setindex!(::SortedArray, args...; kwargs...)
    error("setindex! not allowed for a SortedArray")
end

function Base.pushfirst!(::SortedArray, args...; kwargs...)
    error("pushfirst! not allowed for a SortedArray")
end

function Base.insert!(::SortedArray, args...; kwargs...)
    error("insert! not allowed for a SortedArray")
end

function Base.permute!(::SortedArray)
    error("permute! not allowed for a SortedArray")
end

function Base.invpermute!(::SortedArray)
    error("invpermute! not allowed for a SortedArray")
end

function Base.getindex(sa::SortedArray, idx)
    sa.arr[idx]
end

function Base.get(sa::SortedArray, i::Integer, default)
    get(sa.arr, i, default)
end

function Base.popfirst!(sa::SortedArray, args...)
    popfirst!(sa.arr, args...)
end

function Base.pop!(sa::SortedArray, args...)
    pop!(sa.arr, args...)
end

function Base.popat!(sa::SortedArray, args...)
    popat!(sa.arr, args...)
end

function Base.splice!(sa::SortedArray, args...)
    splice!(sa.arr, args...)
end

function Base.deleteat!(sa::SortedArray, args...)
    deleteat!(sa.arr, args...)
end

Base.sort!(sa::SortedArray, args...; kwargs...) = sa

function Base.searchsorted(sa::SortedArray, args...; kwargs...)
    searchsorted(sa.arr, args...; kwargs...)
end
function Base.searchsortedfirst(sa::SortedArray, args...; kwargs...)
    searchsortedfirst(sa.arr, args...; kwargs...)
end
function Base.searchsortedlast(sa::SortedArray, args...; kwargs...)
    searchsortedlast(sa.arr, args...; kwargs...)
end

Base.length(sa::SortedArray) = length(sa.arr)
Base.iterate(sa::SortedArray, args...; kwargs...) = iterate(sa.arr, args...; kwargs...)
function Base.copy(sa::SortedArray)
    SortedArray(copy(sa.arr); sa.opts...)
end

function Base.reverse(sa::SortedArray)
    SortedArray(reverse(sa.arr); sa.opts..., rev=!sa.opts.rev)
end

function Base.permutedims(sa::SortedArray)
    SortedArray(
        permutedims(sa.arr); dims=ifelse(sa.opts.dims == 1, 2, 1), sa.opts.rev, sa.opts.by
    )
end

function Base.push!(sa::SortedArray{T,1,A}, value) where {T,A<:AbstractVector{T}}
    index = searchsortedfirst(sa.arr, value; rev=sa.opts.rev, by=sa.opts.by)
    insert!(sa.arr, index, value)
    return sa
end

function Base.push!(sa::SortedArray{T,N,A}, value) where {T,N,A<:AbstractArray{T,N}}
    error("push! is only supported for 1-dimensional SortedArray")
end

function Base.append!(sa::SortedArray{T,1,A}, values) where {T,A<:AbstractVector{T}}
    append!(sa.arr, values)
    _dosort!(sa.arr; sa.opts...)
    return sa
end

function Base.append!(sa::SortedArray{T,N,A}, values) where {T,N,A<:AbstractArray{T,N}}
    error("append! is only supported for 1-dimensional SortedArray")
end

function Base.vcat(sas::SortedArray{T,1,A}...) where {T,A<:AbstractVector{T}}
    isempty(sas) && return SortedArray{T,1,A}()
    new_arr = vcat([sa.arr for sa in sas]...)
    opts = sas[1].opts
    _dosort!(new_arr; opts.dims, opts.rev, opts.by)
    return SortedArray(new_arr; opts...)
end

function Base.hcat(sas::SortedArray{T,N,A}...) where {T,N,A<:AbstractArray{T,N}}
    if any(sa -> sa.opts.dims != 1, sas)
        error("hcat is only supported for SortedArray with sorting dimension 1")
    end
    new_arr = hcat([sa.arr for sa in sas]...)
    opts = sas[1].opts
    _dosort!(new_arr; dims=1, opts.rev, opts.by)
    return SortedArray(new_arr; dims=1, opts.rev, opts.by)
end

function Base.cat(
    sas::SortedArray{T,N,A}...; dims::Integer
) where {T,N,A<:AbstractArray{T,N}}
    if any(sa -> sa.opts.dims != sas[1].opts.dims, sas)
        error("All SortedArray instances must have the same sorting dimension")
    end
    new_arr = cat([sa.arr for sa in sas]...; dims=dims)
    opts = sas[1].opts
    new_dims = opts.dims + (dims <= opts.dims)
    _dosort!(new_arr; dims=new_dims, opts.rev, opts.by)
    return SortedArray(new_arr; dims=new_dims, opts.rev, opts.by)
end

Base.size(sa::SortedArray) = size(sa.arr)
function Base.similar(sa::SortedArray, ::Type{S}, dims::Dims) where {S}
    SortedArray(similar(sa.arr, S, dims); sa.opts...)
end
Base.empty!(sa::SortedArray) = (empty!(sa.arr); sa)
function Base.empty(sa::SortedArray)
    SortedArray(empty(sa.arr); sa.opts...)
end
Base.isempty(sa::SortedArray) = isempty(sa.arr)
Base.firstindex(sa::SortedArray) = firstindex(sa.arr)
Base.lastindex(sa::SortedArray) = lastindex(sa.arr)
Base.axes(sa::SortedArray) = axes(sa.arr)
Base.eltype(::Type{SortedArray{A}}) where {A<:AbstractArray} = eltype(A)
Base.collect(sa::SortedArray) = collect(sa.arr)

function Base.map(f, sa::SortedArray)
    new_arr = map(f, sa.arr)
    SortedArray(new_arr; sa.opts...)
end

function Base.filter(f, sa::SortedArray)
    new_arr = filter(f, sa.arr)
    SortedArray(new_arr; sa.opts...)
end

Base.reduce(f, sa::SortedArray; kwargs...) = reduce(f, sa.arr; kwargs...)
Base.foldl(f, sa::SortedArray; kwargs...) = foldl(f, sa.arr; kwargs...)
Base.any(f::Function, sa::SortedArray) = any(f, sa.arr)
Base.all(f::Function, sa::SortedArray) = Base.all(f, sa.arr)
Base.in(x, sa::SortedArray) = in(x, sa.arr)

function Base.show(
    io::IO, ::MIME"text/plain", sa::SortedArray{T,N,A}
) where {T,N,A<:AbstractArray{T,N}}
    print(io, "SortedArray{$T,$N}(")
    print(io, sa.arr)
    print(io, "; dims=$(sa.opts.dims), rev=$(sa.opts.rev), by=$(sa.opts.by))")
end

function Base.map!(f, sa::SortedArray, src::AbstractArray...)
    map!(f, sa.arr, src...)
    _dosort!(sa.arr; sa.opts...)
    return sa
end

function Base.filter!(f, sa::SortedArray)
    filter!(f, sa.arr)
    _dosort!(sa.arr; sa.opts...)
    return sa
end

Base.view(sa::SortedArray, args...) = view(sa.arr, args...)

function Base.resize!(sa::SortedArray, n)
    resize!(sa.arr, n)
    _dosort!(sa.arr; sa.opts...)
    return sa
end

function Base.unique!(sa::SortedArray)
    unique!(sa.arr)
    return sa
end

function Base.unique(sa::SortedArray)
    SortedArray(unique(sa.arr); sa.opts...)
end

function Base.intersect(sa1::SortedArray, sa2::SortedArray)
    SortedArray(intersect(sa1.arr, sa2.arr); sa1.opts...)
end

function Base.union(sa1::SortedArray, sa2::SortedArray)
    SortedArray(union(sa1.arr, sa2.arr); sa1.opts...)
end

function Base.setdiff(sa1::SortedArray, sa2::SortedArray)
    SortedArray(setdiff(sa1.arr, sa2.arr); sa1.opts...)
end

function Base.findall(f::Function, sa::SortedArray)
    SortedArray(findall(f, sa.arr); sa.opts...)
end

function Base.findfirst(f::Function, sa::SortedArray)
    findfirst(f, sa.arr)
end

function Base.findlast(f::Function, sa::SortedArray)
    findlast(f, sa.arr)
end

Base.sum(sa::SortedArray) = sum(sa.arr)
Base.prod(sa::SortedArray) = prod(sa.arr)
Base.maximum(sa::SortedArray) = maximum(sa.arr)
Base.minimum(sa::SortedArray) = minimum(sa.arr)

function Base.broadcast(f, sa::SortedArray, args...)
    result = broadcast(f, sa.arr, args...)
    SortedArray(_dosort!(result; sa.opts...); sa.opts...)
end

Base.sort(sa::SortedArray) = copy(sa)

Base.issorted(::SortedArray) = true

function Base.merge(sa1::SortedArray, sa2::SortedArray)
    SortedArray(merge(sa1.arr, sa2.arr); sa1.opts...)
end

function Base.merge!(sa1::SortedArray, sa2::SortedArray)
    merge!(sa1.arr, sa2.arr)
    _dosort!(sa1.arr; sa1.opts...)
    return sa1
end

function Base.partialsort(sa::SortedArray, k; kwargs...)
    SortedArray(partialsort(sa.arr, k; kwargs...); sa.opts...)
end

function Base.partialsortperm(sa::SortedArray, k; kwargs...)
    SortedArray(partialsortperm(sa.arr, k; kwargs...); sa.opts...)
end

function Base.accumulate(f, sa::SortedArray; dims=sa.opts.dims)
    result = accumulate(f, sa.arr; dims=dims)
    SortedArray(result; sa.opts...)
end

Base.cumsum(sa::SortedArray; dims=1) = accumulate(+, sa; dims=dims)

function serialize(s::AbstractSerializer, sa::A) where {A<:SortedArray}
    serialize_type(s, A, false)
    serialize(s, (sa.arr, sa.opts))
end

function deserialize(buf::AbstractSerializer, ::Type{<:SortedArray})
    arr, opts = deserialize(buf)
    SortedArray(arr; opts...)
end

function Base.sizehint!(sa::SortedArray, v)
    sizehint!(sa.arr, v)
end

export SortedArray
