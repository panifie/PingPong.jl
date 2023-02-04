using Zarr
using Zarr: AbstractStore, DirectoryStore, is_zarray, isemptysub
using Misc: DATA_PATH, isdirempty
using Lang: @lget!
import Base.delete!

const compressor = Zarr.BloscCompressor(; cname="zstd", clevel=2, shuffle=true)

function delete!(g::ZGroup, key::AbstractString; force=true)
    delete!(g.storage, g.path, key)
    if key ∈ keys(g.groups)
        delete!(g.groups, key)
    else
        delete!(g.arrays, key)
    end
end

function delete!(store::DirectoryStore, paths...; recursive=true)
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

istypeorval(t::Type, v) = v isa t
istypeorval(t::Type, v::Type) = v <: t
default(t::Type) = begin
    if applicable(zero, (t,))
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

macro zcreate()
    type = esc(:type)
    key = esc(:key)
    sz = esc(:sz)
    zi = esc(:zi)
    quote
        zcreate(
            $type,
            $(zi).store,
            $(sz)...;
            fill_value=default($(esc(:type))),
            fill_as_missing=false,
            path=$key,
            compressor=compressor
        )
    end
end

function _get_zarray(
    zi::ZarrInstance, key::AbstractString, sz::Tuple; type, overwrite, reset
)
    existing = false
    if is_zarray(zi.store, key)
        za = zopen(zi.store, "w"; path=key)
        if ndims(za) != length(sz) || (ndims(za) > 1 && size(za, 2) != sz[2]) || reset
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
