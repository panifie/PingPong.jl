using Zarr
using Backtest.Misc: default_data_path
import Base.delete!


const compressor = Zarr.BloscCompressor(cname="zstd", clevel=2, shuffle=true)

function delete!(g::ZGroup, key::AbstractString; force=true)
    rm(joinpath(g.storage.folder, g.path, key); force, recursive=true)
    if key ∈ keys(g.groups)
        delete!(g.groups, key)
    else
        delete!(g.arrays, key)
    end
end

function delete!(z::ZArray, ok=true)
    ok && rm(joinpath(z.storage.folder, z.path); force=true, recursive=true)
end

@doc "Candles data is stored with hierarchy PAIR -> [TIMEFRAMES...]. A pair is a ZGroup, a timeframe is a ZArray."
mutable struct ZarrInstance
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

const zi = ZarrInstance()


# zsave(zi::ZarrInstance, data, path::AbstractString) = zsave(zi, data, splitpath(path)...)

# function zsave(zi::ZarrInstance, data, path::Vararg{AbstractString}; type=Float64, merge_fun::Union{Nothing, Function}=nothing)
#     folder = joinpath(path[begin:end-1]...)
#     name = path[end]
#     # zg::Union{Nothing, ZGroup} = nothing
#     local zg
#     if Zarr.is_zgroup(zi.store, folder)
#         zg = zopen(zi.store, "w"; path=folder)
#     else
#         if !Zarr.isemptysub(zi.store, folder)
#             rm(joinpath(zi.store.folder, folder); recursive=true)
#         end
#         zg = zgroup(zi.store, folder)
#     end
#     local za
#     if name in keys(zg.arrays)
#         za = zg[name]
#         # check if the array is empty
#         if Zarr.isemptysub(zg.storage, joinpath(folder, name)) || isnothing(merge_fun)
#             za[:] = data
#         else
#             prev = reshape(za[:], size(za))
#             mdata = merge_fun(prev, data)
#             resize!(za, size(mdata)...)
#             for (n, col) in enumerate(names(mdata))
#                 za[:, n] = mdata[:, col]
#             end
#             za[:, :] .= mdata[:, :]
#         end
#     else
#         za = Zarr.zcreate(type, zg, string(name), size(data)...; compressor)
#         za[:] = data
#     end
#     za, zg
# end
