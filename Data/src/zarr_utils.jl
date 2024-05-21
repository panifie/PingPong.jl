using Reexport
@reexport using Zarr
using Zarr: AbstractStore, DirectoryStore, is_zarray, isemptysub, ZArray
using .TimeTicks
using Misc: DATA_PATH, isdirempty
using .Lang: @lget!, Option
using .Lang.Preferences
import Base: delete!, isempty, empty!

@doc "Default zarr compressor used in the module (zstd, clevel=2)."
const compressor = Zarr.BloscCompressor(; cname="zstd", clevel=2, shuffle=true)

@doc """Resizes a ZArray to zero.

$(TYPEDSIGNATURES)
"""
empty!(z::ZArray) = begin
    resize!(z, 0, size(z)[2:end]...)
    z
end

@doc """A ZArray is empty if its size is 0.

$(TYPEDSIGNATURES)
"""
isempty(z::ZArray) = size(z, 1) == 0

@doc """Removes all arrays and groups from a ZGroup.

$(TYPEDSIGNATURES)
"""
function empty!(g::ZGroup)
    for a in keys(g.arrays)
        delete!(g, a)
    end
    for sg in values(g.groups)
        empty!(sg)
    end
end

@doc "Delete an element from a `ZGroup`. If the element is a group, it will be recursively deleted."
function delete!(g::ZGroup, key::AbstractString; force=true)
    delete!(g.storage, g.path, key)
    if key ∈ keys(g.groups)
        delete!(g.groups, key)
    else
        delete!(g.arrays, key)
    end
end

@doc """Delete an element from a `DirectoryStore`. Also removes the directory.

$(TYPEDSIGNATURES)
"""
function delete!(store::DirectoryStore, paths::Vararg{String}; recursive=true)
    rm(joinpath(store.folder, paths...); force=true, recursive)
end

function delete!(store::AbstractStore, paths...; recursive=true)
    delete!(store, paths...; recursive)
end

@doc """Delete the `ZArray` from the underlying storage.

$(TYPEDSIGNATURES)
"""
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

@doc """Delete elements from a `ZArray` `z` within a specified date range.

$(TYPEDSIGNATURES)

This function deletes elements from a `ZArray` `z` that fall within the specified date range. The range is defined by `from_dt` (inclusive) and `to_dt` (exclusive). The deletion is performed in place.

The `by` argument is optional and defaults to the `identity` function. It specifies the function used to extract the date value from each element of the `ZArray`.
The `select` argument is optional and defaults to a function that selects the first column of each element in the `ZArray`. It specifies the function used to select the relevant portion of each element for deletion.
The `serialized` argument is optional and defaults to `false`. If set to `true`, the `ZArray` is assumed to be serialized, and the deletion is performed on the serialized representation.
The `buffer` argument is optional and can be used to provide an `IOBuffer` for intermediate storage during deletion.
"""
function zdelete!(
    z::ZArray,
    from_dt::Option{DateTime},
    to_dt::Option{DateTime};
    by=identity,
    select=x -> view(x, :, 1),
    serialized=false,
    buffer::Option{IOBuffer}=nothing,
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
@doc """Get the default value of a given type t.

$(TYPEDSIGNATURES)

This function returns the default value of the specified type t.
"""
default_value(t::T) where {T<:Type} = begin
    if applicable(zero, t)
        zero(t)
    elseif applicable(empty, Tuple{t})
        empty(t)
    elseif istypeorval(AbstractString, t)
        ""
    elseif istypeorval(AbstractChar, t)
        '\0'
    elseif istypeorval(Tuple, t)
        ((default_value(ft) for ft in fieldtypes(t))...,)
    elseif istypeorval(NamedTuple, t)
        NamedTuple(k => default_value(ft) for (k, ft) in zip(fieldnames(t), fieldtypes(t)))
    elseif istypeorval(DateTime, t)
        DateTime(0)
    elseif t isa Function
        (_...) -> nothing
    elseif applicable(t)
        t()
    elseif t isa Union && t.a == Nothing
        default_value(t.b)
    else
        throw(ArgumentError("No default value for type: $t"))
    end
end

default_value(f::Function) =
    for t in Base.return_types(f)
        if t ∉ (UnionAll, Any)
            return default_value(t)
        end
    end

@doc "Candles data is stored with hierarchy PAIR -> [TIMEFRAMES...]. A pair is a ZGroup, a timeframe is a ZArray.

$(FIELDS)
"
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

function _addkey!(zi::ZarrInstance, z::ZArray)
    z.path ∉ keys(zi.group.arrays) && (zi.group.arrays[z.path] = z)
end

@doc """Create a ZArray using the zcreate macro.

$(TYPEDSIGNATURES)

This macro is used to create a ZArray object. It provides a convenient syntax for creating and initializing a ZArray with the specified elements.
It's a dirty macro. Uses existing variables:
- `type`: eltype of the array.
- `key`: path of the array.
- `sz`: size of the array.
- `zi`: ZarrInstance object.
"""
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
                fill_value=default_value($(esc(:type))),
                fill_as_missing=false,
                path=$key,
                compressor=compressor,
            )
            _addkey!($zi, z)
            resize!(z, 0, $(sz)[2:end]...)
            z
        end
    end
end

_wrongdims(za, sz) = ndims(za) != length(sz)
_wrongcols(za, sz) = ndims(za) > 1 && size(za, 2) != sz[2]

@doc """Get a ZArray object from a ZarrInstance.

$(TYPEDSIGNATURES)

This function is used to retrieve a ZArray object from a ZarrInstance. It takes in the ZarrInstance, key, size, and other optional parameters and returns the ZArray object.
"""
function _get_zarray(
    zi::ZarrInstance, key::AbstractString, sz::Tuple; type, overwrite, reset
)
    existing = false
    if is_zarray(zi.store, key)
        za = zopen(zi.store, "w"; path=key)
        if isempty(za) || _wrongdims(za, sz) || _wrongcols(za, sz) || reset
            @debug "_get_zarray" sz _wrongdims(za, sz) _wrongcols(za, sz)
            if overwrite || reset
                delete!(zi.store, key; recursive=true)
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
            @debug "Deleting garbage at path $key"
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

const ZINSTANCE_INIT_FUNC = Ref{Union{Function,Type}}(ZarrInstance)
if @load_preference("data_store", "lmdb") == "lmdb"
    using LMDB: LMDB as lm
    if lm.LibLMDB.LMDB_jll.is_available()
        include("lmdbstore.jl")
        ZINSTANCE_INIT_FUNC[] = zilmdb
    end
end
zinstance(args...; kwargs...) = ZINSTANCE_INIT_FUNC[](args...; kwargs...)

const zi = Ref{Option{ZarrInstance}}()
const zcache = Dict{String,ZarrInstance}()
