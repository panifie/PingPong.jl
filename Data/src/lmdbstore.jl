using Zarr: Zarr;
const za = Zarr;
using LMDB: LMDB;
const lm = LMDB;

struct LMDBDictStore <: za.AbstractDictStore
    a::lm.LMDBDict
    LMDBDictStore(path::AbstractString) = begin
        !ispath(path) && mkpath(path)
        new(lm.LMDBDict{String,Vector{UInt8}}(path))
    end
end

Base.filter!(f, d::lm.LMDBDict) = begin
    collect(v for v in pairs(d) if f(v))
end

@doc "Create a `ZarrInstance` at specified `path` using `lmdb` as backend."
zilmdb(path::AbstractString=joinpath(DATA_PATH, "lmdb")) = begin
    store =  LMDBDictStore(path)
    if !Zarr.is_zgroup(store, "")
        zgroup(store, "")
    end
    @debug "Data: opening store $store"
    g = zopen(store, "w")
    ZarrInstance(path, store, g)
end
