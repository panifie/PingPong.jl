using Zarr
using Serialization
using TimeTicks
using Core: _setsuper!
using Base: GenericIOBuffer
using Zarr: AbstractStore, DirectoryStore, is_zarray, isemptysub, ZArray
using Misc: DATA_PATH, isdirempty
using Lang: @lget!, Option
import Base.delete!, Base.isempty, Base.empty!

const compressor = Zarr.BloscCompressor(; cname="zstd", clevel=2, shuffle=true)

empty!(z::ZArray) = begin
    resize!(z, 0, size(z)[2:end]...)
    z
end

isempty(z::ZArray) = size(z, 1) == 0

function delete!(g::ZGroup, key::AbstractString; force=true)
    delete!(g.storage, g.path, key)
    if key ∈ keys(g.groups)
        delete!(g.groups, key)
    else
        delete!(g.arrays, key)
    end
end

function delete!(store::DirectoryStore, paths::Vararg{String}; recursive=true)
    rm(joinpath(store.folder, paths...); force=true, recursive)
end

function delete!(store::AbstractStore, paths...; recursive=true)
    delete!(store, paths...; recursive)
end

function delete!(z::ZArray; ok=true)
    ok && begin
        delete!(z.storage, z.path; recursive=true)
        store_type = typeof(z.storage)
        @assert store_type <: DirectoryStore || store_type <: LMDBDictStore "$store_type does not support array deletion."
    end
end

_setup_buffer(serialized, buffer) = begin
    if serialized
        if isnothing(buffer)
            IOBuffer(), true
        else
            buffer, false
        end
    else
        nothing, false
    end
end

@doc "Delete elements from a `ZArray` within the range of dates `from_dt:to_dt`.

Use the `select` function to customize the dates vector where to index th range. Defaults
to the first column of a 2D Zarray."
function zdelete!(
    z::ZArray,
    from_dt::Option{DateTime},
    to_dt::Option{DateTime};
    by=identity,
    select=x -> view(x, :, 1),
    serialized=false,
    buffer::Option{IOBuffer}=nothing
)
    selected::AbstractVector = select(z)
    buffer, close_buffer = _setup_buffer(serialized, buffer)
    try
        newsize(dim1) = (dim1, size(z)[2:end]...)
        by_func = serialized ? x -> todata(buffer, by(x)) : by
        function search_from()
            from = serialized ? tobytes(from_dt) : convert(eltype(z), from_dt)
            searchsortedfirst(selected, from; by=by_func)
        end
        function search_to(from_idx)
            to = serialized ? tobytes(to_dt) : convert(eltype(z), to_dt)
            searchsortedlast(view(selected, from_idx:lastindex(selected)), to; by=by_func) +
            from_idx
        end
        if isnothing(from_dt)
            if isnothing(to_dt)
                throw(ArgumentError("Couldn't parse $from and $to as dates."))
            else
                # Delete all entries where dates are less than `to`
                to_idx = search_to(firstindex(selected))
                tail_range = (to_idx+1):lastindex(z, 1)
                tail_len = length(tail_range)
                if tail_len > 0
                    z[begin:tail_len, :] = view(z, tail_range, :)
                    resize!(z, newsize(tail_len))
                else
                    resize!(z, newsize(0))
                end
            end
        elseif isnothing(to_dt)
            # Delete all entries where dates are greater than `from`
            from_idx = search_from()
            resize!(z, newsize(from_idx - 1))
        else
            # Delete all entries where dates are greater than `from`
            # and less than `to`
            from_idx = search_from()
            to_idx = search_to(from_idx)
            right_range = (to_idx+1):lastindex(z, 1)
            # the last idx of the copied over data
            end_idx = from_idx + length(right_range) - 1
            if length(right_range) > 0
                z[from_idx:end_idx, :] = view(z, right_range, :)
            end
            resize!(z, newsize(end_idx))
        end
    finally
        close_buffer && close(buffer)
    end
end

_nothing(v) = v != "" ? v : nothing

function Base.delete!(z::ZArray, to::S, from::S=""; kwargs...) where {S<:AbstractString}
    (from_dt, to_dt) = from_to_dt(from, to)
    zdelete!(z, _nothing(from_dt), _nothing(to_dt); kwargs...)
end

istypeorval(t::Type, v) = v isa t
istypeorval(t::Type, v::Type) = v <: t
default(t::Type) = begin
    if applicable(zero, t)
        zero(t)
    elseif applicable(empty, Tuple{t})
        empty(t)
    elseif istypeorval(AbstractString, t)
        ""
    elseif istypeorval(AbstractChar, t)
        '\0'
    elseif istypeorval(Tuple, t)
        ((default(ft) for ft in fieldtypes(t))...,)
    elseif istypeorval(DateTime, t)
        DateTime(0)
    elseif t isa Function
        (_...) -> nothing
    elseif applicable(t)
        t()
    else
        throw(ArgumentError("No default value for type: $t"))
    end
end

@doc "Candles data is stored with hierarchy PAIR -> [TIMEFRAMES...]. A pair is a ZGroup, a timeframe is a ZArray."
mutable struct ZarrInstance{S<:AbstractStore}
    path::AbstractString
    store::S
    group::ZGroup
    ZarrInstance(path, store, g) = new{typeof(store)}(path, store, g)
    function ZarrInstance(data_path=joinpath(DATA_PATH, "store"))
        @lget! zcache data_path begin
            ds = DirectoryStore(data_path)
            if !Zarr.is_zgroup(ds, "")
                @assert isdirempty(data_path) "Directory at $(data_path) must be empty."
                zgroup(ds, "")
            end
            @debug "Data: opening store $ds"
            g = zopen(ds, "w")
            new{DirectoryStore}(data_path, ds, g)
        end
    end
end

const zi = Ref{ZarrInstance}()
const zcache = Dict{String,ZarrInstance}()

function _addkey!(zi::ZarrInstance, z::ZArray)
    z.path ∉ keys(zi.group.arrays) && (zi.group.arrays[z.path] = z)
end

macro zcreate()
    type = esc(:type)
    key = esc(:key)
    sz = esc(:sz)
    zi = esc(:zi)
    quote
        let z = zcreate(
                $type,
                $(zi).store,
                $(sz)...;
                fill_value=default($(esc(:type))),
                fill_as_missing=false,
                path=$key,
                compressor=compressor
            )
            _addkey!($zi, z)
            resize!(z, 0, $(sz)[2:end]...)
            z
        end
    end
end

_wrongdims(za, sz) = ndims(za) != length(sz)
_wrongcols(za, sz) = ndims(za) > 1 && size(za, 2) != sz[2]

function _get_zarray(
    zi::ZarrInstance, key::AbstractString, sz::Tuple; type, overwrite, reset
)
    existing = false
    if is_zarray(zi.store, key)
        za = zopen(zi.store, "w"; path=key)
        if _wrongdims(za, sz) || _wrongcols(za, sz) || reset
            @debug "wrong dims? $(_wrongdims(za, sz)), wrong cols? $(_wrongcols(za, sz))"
            if overwrite || reset
                delete!(zi.store, key)
                za = @zcreate
            else
                throw(
                    "Dimensions mismatch between stored data $(size(za)) and new data. $(sz)",
                )
            end
        else
            existing = true
        end
    else
        if !isemptysub(zi.store, key)
            @debug "Deleting garbage at path $p"
            delete!(zi.store, key)
        end
        za = @zcreate
    end
    (za, existing)
end

@doc "Remove duplicate from a zarray.

In a 2d zarray where we want values where the second column is unique:
```julia
unique!(x->x[2], z)
```
"
function Base.unique!(by::Function, z::ZArray; dims=1)
    u = Base.unique(by, eachslice(z; dims))
    sz = [size(z)...]
    sz[dims] = length(u)
    resize!(z, tuple(sz...))
    slice_len = length(first(u))
    z[:] = reduce(vcat, [reshape(el, (1, slice_len)) for el in u])
end
