using Zarr: Zarr as za;
using LMDB: LMDB as lm;
using Lang: @lget!

const MB = 1024 * 1024
struct LMDBDictStore <: za.AbstractDictStore
    a::lm.LMDBDict
    lock::ReentrantLock
    function LMDBDictStore(path::AbstractString; reset=false, mapsize=64MB)
        reset && rm(path; recursive=true)
        !ispath(path) && mkpath(path)
        d = new(lm.LMDBDict{String,Vector{UInt8}}(path), ReentrantLock())
        d.a.env[:MapSize] = mapsize
        d
    end
end

mapsize(store::LMDBDictStore) = convert(Int, lm.info(store.a.env).me_mapsize)
function mapsize!(store::LMDBDictStore, mb)
    # FIXME: setindex! on the `lm.Environment` converts Ints to UInt32 limiting mapsize to <4GB
    # store.a.env[:MapSize] = round(Int, mb * MB)
    @lock store.lock begin
        lm.mdb_env_set_mapsize(store.a.env.handle, Cuintmax_t(round(Int, mb * MB)))
    end
end
mapsize!!(store::LMDBDictStore, mb) = mapsize!(store, (mapsize(store) / MB + mb) * MB)
mapsize!!(store::LMDBDictStore, prc::AbstractFloat) = begin
    sz = mapsize(store) ÷ MB
    mapsize!(store, sz + sz * prc)
end

function Base.setindex!(d::LMDBDictStore, v, i::AbstractString)
    try
        d.a[i] = v
    catch e
        if e isa lm.LMDBError && e.code == -30792
            mapsize!!(d, 0.1)
            Base.setindex!(d, v, i)
        else
            rethrow(e)
        end
    end
end

Base.filter(f, d::lm.LMDBDict{K,V}) where {K,V} = begin
    collect(v for v in pairs(d) if f(v))
end

Base.delete!(store::LMDBDictStore, k; recursive=false) = delete!(store.a, k; prefix=k)

_withsuffix(p, sf='/') = (isempty(p) || endswith(p, sf)) ? p : p * sf

za._pkeys(d::LMDBDictStore, p) = keys(d.a; prefix=_withsuffix(p))
za._pdict(d::LMDBDictStore, p) = dictview(d.a, keys(d.a; prefix=_withsuffix(p)))

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
