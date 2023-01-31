zsave(zi::ZarrInstance, data, path::AbstractString) = zsave(zi, data, splitpath(path)...)

function zsave(
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

@doc """
`data_col`: the timestamp column of the new data (1)
`saved_col`: the timestamp column of the existing data (1)
`key`: the full key of the zarr group to use
`type`: Primitive type used for storing the data (Float64)
"""
function save_data(zi::ZarrInstance, key, data; kwargs...)
    try
        _save_data(zi, key, data; kwargs...)
    catch e
        if typeof(e) ∈ (MethodError, DivideError, TimeFrameError)
            @warn "Resetting local data for key $key." e
            _save_data(zi, key, data; kwargs..., reset=true)
        else
            rethrow(e)
        end
    end
end

function _save_data(
    zi::ZarrInstance,
    key,
    data;
    type=Float64,
    data_col=1,
    saved_col=1,
    overwrite=true,
    reset=false,
)
    local za

    za, existing = _get_zarray(zi, key, size(data); type, overwrite, reset)

    @debug "Zarr dataset for key $key, len: $(size(data))."
    if !reset && existing && size(za, 1) > 0
        local data_view
        saved_first_ts = za[begin, saved_col]
        saved_last_ts = za[end, saved_col]
        data_first_ts = timefloat(data[begin, data_col])
        data_last_ts = timefloat(data[end, data_col])
        # if appending data
        if data_first_ts >= saved_first_ts
            if overwrite
                # when overwriting get the index where data starts overwriting storage
                offset = searchsortedfirst(@view(za[:, saved_col]), data_first_ts)
                data_view = @view data[:, :]
                @debug dt(data_first_ts), dt(saved_last_ts), dt(saved_last_ts + td)
                @debug :saved, dt.(za[end, saved_col]) :data, dt.(data[1, data_col]) :saved_off,
                dt(za[offset, data_col])
                @assert timefloat(data[1, data_col]) === za[offset, saved_col]
            else
                # when not overwriting get the index where data has new values
                data_offset = searchsortedlast(@view(data[:, data_col]), saved_last_ts) + 1
                offset = size(za, 1) + 1
                if data_offset <= size(data, 1)
                    data_view = @view data[data_offset:end, :]
                    @debug :saved, dt(za[end, saved_col]) :data_new,
                    dt(data[data_offset, data_col])
                    @assert za[end, saved_col] + td ===
                        timefloat(data[data_offset, data_col])
                else
                    data_view = @view data[1:0, :]
                end
            end
            szdv = size(data_view, 1)
            if szdv > 0
                resize!(za, (offset - 1 + szdv, size(za, 2)))
                za[offset:end, :] = @to_mat(data_view)
                @debug _contiguous_ts(za[:, saved_col], td)
            end
            @debug "Size data_view: " szdv
            # inserting requires overwrite
        else
            # fetch the saved data and combine with new one
            # fetch saved data starting after the last date of the new data
            # which has to be >= saved_first_date because we checked for contig
            saved_offset = Int(max(1, (data_last_ts - saved_first_ts + td) ÷ td))
            saved_data = za[(saved_offset + 1):end, :]
            szd = size(data, 1)
            ssd = size(saved_data, 1)
            n_cols = size(za, 2)
            @debug ssd + szd, n_cols
            # the new size will include the amount of saved date not overwritten by new data plus new data
            resize!(za, (ssd + szd, n_cols))
            za[(szd + 1):end, :] = saved_data
            za[begin:szd, :] = @to_mat(data)
            @debug :data_last, dt(data_last_ts) :saved_first, dt(saved_first_ts)
        end
        @debug "Ensuring contiguity in saved data $(size(za))." _contiguous_ts(
            za[:, data_col], td
        )
    else
        resize!(za, size(data))
        za[:, :] = @to_mat(data)
    end
    return za
end
