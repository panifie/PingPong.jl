using Zarr
import Base.delete!

const default_data_path = get(ENV, "XDG_CACHE_DIR", "$(joinpath(ENV["HOME"], ".cache", "Backtest.jl", "data"))")

function delete!(g::ZGroup, key::AbstractString; force=true)
    rm(joinpath(g.storage.folder, g.path, key); force, recursive=true)
    if key ∈ keys(g.groups)
        delete!(g.groups, key)
    else
        delete!(g.arrays, key)
    end
end

function delete!(z::ZArray, _)
    zg = zopen(za.storage, dirname(z.path))
    delete!(zg, basename(z))
end

@doc "Candles data is stored with hierarchy PAIR -> [TIMEFRAMES...]. A pair is a ZGroup, a timeframe is a ZArray."
struct ZarrInstance
    path::AbstractString
    store::DirectoryStore
    group::ZGroup
    function ZarrInstance(data_path=default_data_path)
        ds = DirectoryStore(data_path)
        if !Zarr.is_zgroup(ds, "")
            zgroup(ds)
        end
        g = zopen(ds, "w")
        new(data_path, ds, g)
    end
end

zsave(zi::ZarrInstance, data, path::AbstractString) = zsave(zi, data, splitpath(path)...)


function zsave(zi::ZarrInstance, data, path::Vararg{AbstractString}; type=Float64, merge_fun::Union{Nothing, Function}=nothing)
    folder = joinpath(path[begin:end-1]...)
    name = path[end]
    # zg::Union{Nothing, ZGroup} = nothing
    local zg
    if Zarr.is_zgroup(zi.store, folder)
        zg = zopen(zi.store, "w"; path=folder)
    else
        if !Zarr.isemptysub(zi.store, folder)
            rm(joinpath(zi.store.folder, folder); recursive=true)
        end
        zg = zgroup(zi.store, folder)
    end
    local za
    if name in keys(zg.arrays)
        za = zg[name]
        # check if the array is empty
        if Zarr.isemptysub(zg.storage, joinpath(folder, name)) || isnothing(merge_fun)
            za[:] = data
        else
            prev = reshape(za[:], size(za))
            mdata = merge_fun(prev, data)
            resize!(za, size(mdata)...)
            for (n, col) in enumerate(names(mdata))
                za[:, n] = mdata[:, col]
            end
            za[:, :] .= mdata[:, :]
        end
    else
        za = Zarr.zcreate(type, zg, string(name), size(data)...)
        za[:] = data
    end
    za, zg
end
