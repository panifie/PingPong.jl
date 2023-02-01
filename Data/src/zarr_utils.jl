using Zarr
using Zarr: AbstractStore, DirectoryStore, is_zarray
using Misc: DATA_PATH, isdirempty
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

default(t::Type) = begin
    if hasmethod(zero, (t,))
        zero(t)
    elseif hasmethod(empty, Tuple{t})
        empty(t)
    elseif t <: AbstractString
        ""
    elseif t <: AbstractChar
        '\0'
    elseif t <: Function
        (_...) -> nothing
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

const zi = Ref{ZarrInstance}()

function _get_zarray(
    zi::ZarrInstance, key::AbstractString, sz::Tuple; type, overwrite, reset
)
    existing = false
    if is_zarray(zi.store, key)
        za = zopen(zi.store, "w"; path=key)
        if ndims(za) != length(sz) || (ndims(za) > 1 && size(za, 2) != sz[2]) || reset
            if overwrite || reset
                delete!(zi.store, key)
                za = zcreate(
                    type,
                    zi.store,
                    sz...;
                    fill_value=default(type),
                    fill_as_missing=false,
                    path=key,
                    compressor=compressor,
                )
            else
                throw(
                    "Dimensions mismatch between stored data $(size(za)) and new data. $(sz)",
                )
            end
        else
            existing = true
        end
    else
        if !Zarr.isemptysub(zi.store, key)
            p = joinpath(zi.store.folder, key)
            @debug "Deleting garbage at path $p"
            rm(p; recursive=true)
        end
        za = zcreate(type, zi.store, sz...; path=key, compressor)
    end
    (za, existing)
end
