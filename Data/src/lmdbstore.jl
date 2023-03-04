using Zarr: Zarr;
const za = Zarr;
using LMDB: LMDB;
const lm = LMDB;
using Lang: @lget!

const MB = 1024 * 1024
struct LMDBDictStore <: za.AbstractDictStore
    a::lm.LMDBDict
    function LMDBDictStore(path::AbstractString; reset=false, mapsize=64 * MB)
        reset && rm(path; recursive=true)
        !ispath(path) && mkpath(path)
        d = new(lm.LMDBDict{String,Vector{UInt8}}(path))
        d.a.env[:MapSize] = mapsize
        d
    end
end

mapsize(store::LMDBDictStore) = convert(Int, lm.info(store.a.env).me_mapsize)
mapsize!(store::LMDBDictStore, mb) = store.a.env[:MapSize] = mb * MB
mapsize!!(store::LMDBDictStore, mb) = store.a.env[:MapSize] += mb * MB

Base.filter!(f, d::lm.LMDBDict) = begin
    collect(v for v in pairs(d) if f(v))
end

get_zgroup(store) = begin
    if !Zarr.is_zgroup(store, "")
        zgroup(store, "")
    end
    @debug "Data: opening store $store"
    zopen(store, "w")
end

@doc "Create a `ZarrInstance` at specified `path` using `lmdb` as backend.

`force`: resets the underlying store."
function zilmdb(path::AbstractString=joinpath(DATA_PATH, "lmdb"); force=false)
    @lget! zcache path begin
        get(force) = begin
            store = LMDBDictStore(path; reset=force)
            g = get_zgroup(store)
            ZarrInstance(path, store, g)
        end
        try
            get(false)
        catch error
            if force
                get(true)
            else
                rethrow(error)
            end
        end
    end
end

function delete!(store::LMDBDictStore, paths::Vararg{AbstractString}; recursive=true)
    try
        if recursive
            for k in keys(store.a; prefix=joinpath(paths...))
                delete!(store.a, k)
            end
        else
            delete!(store.a, joinpath(paths...))
        end
    catch error
        println(typeof(error))
        println(error)
    end
end

function Base.empty!(d::lm.LMDBDict{K}) where {K}
    lm.txn_dbi_do(d; readonly=false) do txn, dbi
        lm.drop(txn, dbi; delete=true)
    end
    lm.sync(d.env, true)
end

export zilmdb
