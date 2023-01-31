using Zarr
using Zarr: AbstractStore
using Misc: DATA_PATH, isdirempty
import Base.delete!

const compressor = Zarr.BloscCompressor(; cname="zstd", clevel=2, shuffle=true)

function delete!(g::ZGroup, key::AbstractString; force=true)
    rm(joinpath(g.storage.folder, g.path, key); force, recursive=true)
    if key ∈ keys(g.groups)
        delete!(g.groups, key)
    else
        delete!(g.arrays, key)
    end
end

function delete!(z::ZArray, ok=true; kind=:directory)
    ok && begin
        if kind == :directory
            rm(joinpath(z.storage.folder, z.path); force=true, recursive=true)
        elseif kind == :lmdbdict
            delete!(z.storage.a, z.path)
        else
            throw(ArgumentError("$kind is not a valid storage backend."))
        end
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
