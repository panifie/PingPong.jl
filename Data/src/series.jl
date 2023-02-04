using Serialization
using Misc: Iterable

function zsave(zi::ZarrInstance, data, path::AbstractString)
    zsave(zi, data, splitpath(path)...)
end

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

tobytes(buf::IOBuffer, data) = begin
    @debug @assert position(buf) == 0
    serialize(buf, data)
    take!(buf)
end

tobytes(data) = begin
    buf = IOBuffer()
    try
        tobytes(buf, data)
    finally
        close(buf)
    end
end

@doc """
`data`: A type with a `size`.
`data_col`: the timestamp column of the new data (1)
`za_col`: the timestamp column of the existing data (1)
`key`: the full key of the zarr group to use
`type`: Primitive type used for storing the data (Float64)
"""
function save_data(
    zi::ZarrInstance, key, data::Iterable; serialize=false, data_col=1, kwargs...
)
    try
        @assert applicable(iterate, data) lazy"$(typeof(data)) is not iterable."
        @assert length(first(data)) > 1 lazy"Data must have at least 2 dimensions (It needs a timestamp column.)"
        @assert first(data)[data_col] isa DateTime lazy"Element $(first(data))"
    catch e
        @error "Tried to save incompatible data type ($(typeof(data))) using index $data_col as time column."
        rethrow(e)
    end
    if serialize
        buf = IOBuffer()
        # NOTE: this is a matrix
        data = try
            [tobytes(buf, n[p]) for n in data, p in 1:2]
        finally
            close(buf)
        end
        type = Vector{UInt8}
    else
        type = get(kwargs, :type, Float64)
    end
    try
        _save_data(zi, key, data; kwargs..., type)
    catch e
        if typeof(e) ∈ (MethodError, DivideError)
            @warn "Resetting local data for key $key." e
            _save_data(zi, key, data; kwargs..., type, reset=true)
        else
            rethrow(e)
        end
    end
end

@doc """ Saves data to a zarr array ensuring only dates seriality, not contiguity (as opposed to `_save_ohlcv`).

"""
function _save_data(
    zi::ZarrInstance,
    key,
    data;
    type=Float64,
    data_col=1,
    za_col=data_col,
    overwrite=true,
    reset=false,
)
    local za

    za, existing = _get_zarray(zi, key, size(data); type, overwrite, reset)

    @debug "Zarr dataset for key $key, len: $(size(data))."
    if !reset && existing && size(za, 1) > 0
        local data_view
        saved_first_ts = timefloat(za[begin, za_col])
        saved_last_ts = timefloat(za[end, za_col])
        data_first_ts = timefloat(data[begin, data_col])
        data_last_ts = timefloat(data[end, data_col])
        # if appending data
        if data_first_ts >= saved_first_ts
            if overwrite
                # when overwriting get the index where data starts overwriting storage
                offset = searchsortedfirst(@view(za[:, za_col]), data_first_ts, by=timefloat)
                data_view = @view data[:, :]
                begin # checks
                    @debug dt(data_first_ts), dt(saved_last_ts), dt(saved_last_ts + td)
                    @debug :saved (dt.(za[end, za_col])):data,
                    (dt.(data[begin, data_col])):saved_off,
                    dt(za[offset, za_col])
                    @assert if offset <= size(za, 1)
                        timefloat(data[begin, data_col]) === timefloat(za[offset, za_col])
                    else
                        timefloat(data[begin, data_col]) >= timefloat(za[end, za_col])
                    end
                end
            else
                # when not overwriting get the index where data has new values
                data_offset = searchsortedlast(@view(data[:, data_col]), saved_last_ts, by=timefloat) + 1
                offset = size(za, 1) + 1
                if data_offset <= size(data, 1)
                    data_view = @view data[data_offset:end, :]
                    begin # checks
                        @debug :saved dt(za[end, za_col]):data_view,
                        dt(data[data_offset, data_col])
                        @assert timefloat(data[data_offset, data_col]) >= timefloat(za[end, za_col])
                    end
                else
                    data_view = @view data[1:0, :]
                end
            end
            szdv = size(data_view, 1)
            @debug "Size data_view: " szdv
            if szdv > 0
                resize!(za, (offset - 1 + szdv, size(za, 2)))
                za[offset:end, :] = @to_mat(data_view)
                @assert timefloat(za[max(1, offset - 1), za_col]) <= timefloat(data_view[begin, data_col])
            end
        else # inserting requires overwrite
            # data_first_ts < saved_first_ts
            # fetch the saved data and combine with new one
            # fetch saved data starting after the last date of the new data
            # which has to be >= saved_first_date because we checked for contig
            if data_last_ts < saved_first_ts # just concat
            else # data_last_ts >= saved_first_ts
                # have to slice
                saved_offset = searchsortedfirst(@view(za[:, za_col]), data_last_ts, by=timefloat)
                saved_data = if saved_offset > size(za, 1) # new data completely overwrites old data
                    za[begin:0, :]
                else
                    @view za[(saved_offset + 1):end, :]
                end
            end
            szd = size(data, 1)
            ssd = isempty(saved_data) ? 0 : size(saved_data, 1) # an empty Zarray range `(1:0)` returns an empty tuple
            n_cols = size(za, 2)
            @debug "backwriting - new overwritten data len: $(ssd+szd), ncols: $n_cols"
            # the new size will include the amount of saved data not overwritten by new data plus new data
            resize!(za, (ssd + szd, n_cols))
            if ssd > 0
                za[(szd + 1):end, :] = saved_data
            end
            za[begin:szd, :] = @to_mat(data)
            @debug "backwriting - data_last: $(dt(data_last_ts)) saved_first: $(dt(saved_first_ts))"
        end
    else
        resize!(za, size(data))
        za[:, :] = @to_mat(data)
    end
    return za
end

@doc """ Load data from zarr instance.
`zi`: The zarr instance to use
`key`: the name of the array to load from the zarr instance (full key path).
`type`: Set to the type that zarr should use to store the data (only bits types). [Float64].
`serialized`: If set, data will be deserialized before returned (`type` is ignored).
`from`, `to`: date range
"""
function load_data(zi::ZarrInstance, key; serialized=false, kwargs...)
    sz = serialized ? (0, 2) : get(kwargs, :sz, (0, 2))
    try
         _load_data(zi, key, sz; kwargs..., serialized)
    catch e
        if typeof(e) ∈ (MethodError, ArgumentError)
            delete!(zi.store, key) # ensure path does not exist
            emptyz = zcreate(
                serialized ? Vector{UInt8} : get(kwargs, :type, Float64),
                zi.store,
                sz...;
                path=key,
                compressor,
            )
            if :as_z ∈ keys(kwargs)
                return emptyz, (0, 0)
            elseif :with_z ∈ keys(kwargs)
                return nothing, emptyz
            else
                return nothing
            end
        else
            rethrow(e)
        end
    end
end
load_data(key::AbstractString; kwargs...) = load_data(zilmdb(), key; kwargs...)

todata(bytes) = begin
    buf = IOBuffer(bytes)
    try
        deserialize(buf)
    finally
        close(buf)
    end
end
todata(buf::IOBuffer, bytes) = begin
    truncate(buf, 0)
    write(buf, bytes)
    seekstart(buf)
    deserialize(buf)
end

function _load_data(
    zi::ZarrInstance,
    key,
    sz=(0, 2);
    from="",
    to="",
    saved_col=1,
    type=Float64,
    serialized=false,
    as_z=false,
    with_z=false,
)
    @debug "Loading data from $(zi.path):$(key)"
    z_type = serialized ? Vector{UInt8} : type
    za, _ = _get_zarray(zi, key, sz; overwrite=true, type=z_type, reset=false)
    ndims = length(sz)

    def_type = serialized ? Any : type
    function result(; data=Array{def_type,ndims}(undef, sz), startstop=(0, 0))
        as_z && return (; z=za, startstop)
        with_z && return (; data, z=za)
        return data
    end
    size(za, 1) < 1 && return result()

    @as from timefloat(from)
    @as to timefloat(to)

    @debug begin
        saved_first_ts = timefloat(za[begin, saved_col])
        "Saved data first timestamp is $(saved_first_ts |> dt)"
    end

    with_from = !iszero(from)
    with_to = !iszero(to)

    ts_start = if with_from
        searchsortedfirst(@view(za[:, saved_col]), from; by=timefloat)
    else
        firstindex(za, saved_col)
    end
    ts_stop = if with_to
        rev = @view(za[lastindex(za, 1):-1:firstindex(za, 1), saved_col])
        searchsortedfirst(rev, to; by=timefloat)
    else
        lastindex(za, saved_col)
    end

    as_z && return result(; startstop=(ts_start, ts_stop))
    ts_start > size(za, 1) && return result()

    data = za[ts_start:ts_stop, :]

    with_from && @assert timefloat(data[begin, saved_col]) >= from
    with_to && @assert timefloat(data[end, saved_col]) <= to

    out = if serialized
        buf = IOBuffer()
        try
            [
                (; date=todata(buf, data[n, 1]), value=todata(buf, data[n, 2])) for
                n in firstindex(data, 1):size(data, 1)
            ]
        finally
            close(buf)
        end
    else
        data
    end

    result(; data=out)
end

export save_data, load_data
