using Zarr
using Misc: DATA_PATH
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
        end
    end
end

@doc "Candles data is stored with hierarchy PAIR -> [TIMEFRAMES...]. A pair is a ZGroup, a timeframe is a ZArray."
mutable struct ZarrInstance
    path::AbstractString
    store::DirectoryStore
    group::ZGroup
    function ZarrInstance(data_path=DATA_PATH)
        ds = DirectoryStore(data_path)
        if !Zarr.is_zgroup(ds, "")
            zgroup(ds, "")
        end
        @debug "Data: opening store $ds"
        g = zopen(ds, "w")
        new(data_path, ds, g)
    end
end

const zi = Ref{ZarrInstance}()
