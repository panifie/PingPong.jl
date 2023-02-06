function zmerge(zi::ZarrInstance, data, path::AbstractString)
    zsave(zi, data, splitpath(path)...)
end
@doc "Save data to a zarr array by a merging function (like `combine_rows`). The dominant shape is the one from the new data."
function zmerge(
    zi::ZarrInstance,
    data,
    path::Vararg{AbstractString};
    type=Float64,
    merge_fun::Union{Nothing,Function}=nothing,
)
    folder = joinpath(path[begin:(end - 1)]...)
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
        za = Zarr.zcreate(type, zg, string(name), size(data)...; compressor)
        za[:] = data
    end
    za, zg
end
