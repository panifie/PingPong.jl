using Zarr: Zarr as za;
using LMDB: LMDB as lm;
using .Lang: @lget!

const MB = 1024 * 1024
@doc """LMDBDictStore is a concrete implementation of the AbstractDictStore interface.

LMDBDictStore represents a dictionary-like data store that uses LMDB as its backend. It is a subtype of AbstractDictStore defined in the Zarr package.

LMDBDictStore has the following fields:
- `a`: An instance of LMDBDict that represents the LMDB database.
- `lock`: A ReentrantLock used for thread-safety.

LMDBDictStore can be created using the LMDBDictStore constructor function. It takes the following arguments:
- `path::AbstractString`: The path to the LMDB database.
- `reset::Bool=false`: If `true`, the LMDB database at the given path will be deleted and recreated.
- `mapsize::Int=64MB`: The maximum size of the LMDB database.

LMDBDictStore implements the AbstractDictStore interface, which provides methods for reading and writing data to the store.
"""
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

function check_mapsize(data, arr::ZArray)
    if arr.storage isa LMDBDictStore
        # HACK: for this check to be 100% secure, it would have to read data from disk
        # and sum `saved_size` with `new_size` to ensure that the total chunk size is
        # below the LMDB mapsize which we use (our default 64M).
        # Here instead we consider only the size of the saved data.
        chunk_len = arr.metadata.chunks[1]
        chunk_size = 0
        chunk_count = 0
        maxsize = mapsize(arr.storage)
        for n in 1:size(data, 1)
            chunk_size += mapreduce(length, +, data[n])
            chunk_count += 1
            if chunk_count < chunk_len
                @assert chunk_size < maxsize "Size of data exceeded lmdb current map size, reduce objects size or increase mapsize."
            else
                chunk_size = 0
                chunk_count = 0
            end
        end
    end
end

push!(CHECK_FUNCTIONS, check_mapsize)

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

# FIXME: check if the kwargs can be removed (it might be need for disambiguation)
Base.delete!(store::LMDBDictStore, k; recursive=false) = delete!(store.a, k; prefix=k)
Base.length(store::LMDBDictStore) = length(keys(store.a))

_withsuffix(p, sf='/') = (isempty(p) || endswith(p, sf)) ? p : p * sf

za._pkeys(d::LMDBDictStore, p) = keys(d.a; prefix=_withsuffix(p))
za._pdict(d::LMDBDictStore, p) = dictview(d.a, keys(d.a; prefix=_withsuffix(p)))

@doc """Get the root group of a store.

$(TYPEDSIGNATURES)
"""
get_zgroup(store::za.AbstractStore) = begin
    if !Zarr.is_zgroup(store, "")
        zgroup(store, "")
    end
    @debug "Data: opening store $store"
    zopen(store, "w")
end

@doc """Create a ZarrInstance at specified path using lmdb as backend.

$(TYPEDSIGNATURES)

This function creates a ZarrInstance object at the specified path using lmdb as the backend. It has an optional parameter 'force' to reset the underlying store.
"""
function zilmdb(path::AbstractString=joinpath(DATA_PATH, "lmdb"); force=false)
    @lget! zcache path begin
        get(force::Bool) = begin
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

@doc """Delete paths from an LMDBDictStore.

$(TYPEDSIGNATURES)

This function deletes the specified paths from an LMDBDictStore. It supports deleting paths recursively if the `recursive` parameter is set to true.
"""
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

@doc """Empty an LMDBDict object.

$(TYPEDSIGNATURES)

This function empties an LMDBDict object by dropping the lmdb database and syncing the environment.
"""
function Base.empty!(d::lm.LMDBDict)
    lm.txn_dbi_do(d; readonly=false) do txn, dbi
        lm.drop(txn, dbi; delete=true)
    end
    lm.sync(d.env, true)
end

@doc """Remove all lmdb files associated with an LMDBDict object.

$(TYPEDSIGNATURES)

This function removes all lmdb files associated with the given LMDBDict object. It deletes the lmdb database and all associated files.
"""
function Base.rm(d::lm.LMDBDict)
    path = d.env.path
    empty!(d)
    delete!(zcache, path)
    # delete all lmdb files
    mdbfiles = filter(x -> endswith(x, ".mdb"), readdir(path; join=true))
    foreach(rm, mdbfiles)
    # only delete dir if is empty
    isdirempty(path) && rm(path)
end

export zinstance
