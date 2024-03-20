using .Data: @to_mat
using .Lang: @ifdebug

@doc """Check the size of data against a ZArray.

$(TYPEDSIGNATURES)

Used to check the size of data against a ZArray `arr`. It takes in the data and the ZArray `arr` as input.
Compares the size of the data with the size of the ZArray. If the sizes do not match, it raises a `SizeMismatchError`.
"""
function check_data(data, arr::ZArray)
    for f in CHECK_FUNCTIONS
        f(data, arr)
    end
end

@doc """Save data to a ZarrInstance with additional options.

$(TYPEDSIGNATURES)

- `type`: The type of the data to be saved. Default is `Float64`.
- `data_col`: The column of the data to be saved. Default is `1`.
- `z_col`: The column in the Zarr array to save the data. Default is the same as `data_col`.
- `overwrite`: A flag indicating whether to overwrite existing data at the specified key. Default is `true`.
- `reset`: A flag indicating whether to reset the Zarr array before saving the data. Default is `false`.
- `chunk_size`: The size of the chunks to use when saving the data. Default is `nothing`, indicating auto-chunking.

Only dates seriality is ensured, not contiguity (unlike [`save_ohlcv`](@ref))
It creates a new array if needed, sets the chunk size if specified.

"""
function save_data(zi::ZarrInstance, key, data; serialize=false, data_col=1, kwargs...)
    _wrap_save_data(zi::ZarrInstance, key, data; serialize, data_col, kwargs...)
end

function _wrap_save_data(
    zi::ZarrInstance, key, data; serialize=false, data_col=1, kwargs...
)
    try
        @assert applicable(iterate, data) "$(typeof(data)) is not iterable."
        @assert length(first(data)) > 1 "Data must have at least 2 dimensions (It needs a timestamp column.)"
        @assert first(data)[data_col] isa DateTime "Element $(first(data))"
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
        _save_data(zi, key, data; kwargs..., type, data_col)
    catch e
        if typeof(e) ∈ (DivideError,)
            @warn "Resetting local data for key $key." e
            _save_data(zi, key, data; kwargs..., type, data_col, reset=true)
        else
            rethrow(e)
        end
    end
end

function _overwrite_checks(data, za, offset, data_first_ts, saved_last_ts, data_col, z_col)
    @debug "series: overwrite_checks" dt(data_first_ts) dt(saved_last_ts) z_dates = begin
        if !isempty(za)
            (;
                saved=dt(timefloat(za[end, z_col])),
                offset=offset > size(za, 1) ? nothing : timefloat(za[offset, z_col]),
                data=dt(timefloat(data[begin, data_col])),
            )
        end
    end

    if offset <= size(za, 1)
        datatime = timefloat(data[begin, data_col])
        savetime = timefloat(za[offset, z_col])
        @assert datatime <= savetime "$(dt(datatime)) does not match $(dt(savetime))"
    else
        @assert data_first_ts > saved_last_ts "New data ($(dt(data_first_ts))) should be strictly greater than saved data ($(dt(saved_last_ts)))."
    end
end

function _partial_checks(data, za, data_view, data_offset, data_col, z_col)
    @debug let saved = dt(za[end, z_col]), data_view = dt(data[data_offset, data_col])
        "saved: $saved, data_view: $data_view"
    end
    @assert timefloat(data[data_offset, data_col]) >= timefloat(za[end, z_col])
end

function _save_data(
    zi::ZarrInstance,
    key,
    data;
    type=Float64,
    data_col=1,
    z_col=data_col,
    overwrite=true,
    reset=false,
    chunk_size=nothing,
)
    local za

    za, existing = _get_zarray(
        zi, key, @something(chunk_size, chunksize(data)); type, overwrite, reset
    )
    eltype(data) <: Vector{UInt8} && check_data(data, za)

    @debug "Zarr dataset for key $key, len: $(size(data))."
    if !reset && existing && !isempty(za)
        local data_view
        saved_first_ts = timefloat(za[begin, z_col])
        saved_last_ts = timefloat(za[end, z_col])
        data_first_ts = timefloat(data[begin, data_col])
        data_last_ts = timefloat(data[end, data_col])
        # if appending data
        if data_first_ts >= saved_first_ts
            if overwrite
                # when overwriting get the index where data starts overwriting storage
                offset = searchsortedfirst(@view(za[:, z_col]), data_first_ts; by=timefloat)
                data_view = @view data[:, :]
                _overwrite_checks(
                    data, za, offset, data_first_ts, saved_last_ts, data_col, z_col
                )
            else
                # when not overwriting get the index where data has new values
                data_range = rangeafter(
                    @view(data[:, data_col]), saved_last_ts; by=timefloat
                )
                offset = size(za, 1) + 1
                data_view = @view data[data_range, :]
            end
            szdv = size(data_view, 1)
            @debug "Size data_view: " szdv
            if szdv > 0
                resize!(za, (offset - 1 + szdv, size(za, 2)))
                za[offset:end, :] = @to_mat(data_view)
                @assert timefloat(za[max(1, offset - 1), z_col]) <=
                    timefloat(data_view[begin, data_col])
            end
        else # inserting requires overwrite
            # data_first_ts < saved_first_ts
            # load the saved data and combine with new one
            # load saved data starting after the last date of the new data
            # which has to be >= saved_first_date because we checked for contig
            saved_data = if data_last_ts < saved_first_ts # just concat
                ()
            else # data_last_ts >= saved_first_ts
                # have to slice
                saved_offset = searchsortedfirst(
                    @view(za[:, z_col]), data_last_ts; by=timefloat
                )
                if saved_offset > size(za, 1) # new data completely overwrites old data
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

const DEFAULT_CHUNK_SIZE = (100, 2)
@doc """ Load data from zarr instance.

$(TYPEDSIGNATURES)

- `zi`: The zarr instance to use
- `key`: the name of the array to load from the zarr instance (full key path).
- `type`: Set to the type that zarr should use to store the data (only bits types). [Float64].

- `sz`: The chunks tuple which should match the shape of the already saved data.
- `from`: The starting index to load the data from. Default is an empty string, indicating no specific starting index.
- `to`: The ending index to load the data up to. Default is an empty string, indicating no specific ending index.
- `z_col`: The column in the Zarr array to load the data from. Default is `1`.
- `type`: The type of the data to be loaded. Default is `Float64`.
- `serialized`: A flag indicating whether the data is serialized. Default is `false`. If `true`, `type` is ignored.
- `as_z`: A flag indicating whether to return the loaded data as a ZArray. Default is `false`.
- `with_z`: A flag indicating whether to return the loaded data along with the Zarr array (as tuple). Default is `false`.

!!! warning "Mismatching chunks"
    Loading data with from key with wrong dimensions (`ndims(sz)`) or shape (columns)
    will reset the stored zarray.
"""
function load_data(zi::ZarrInstance, key; serialized=false, kwargs...)
    _wrap_load_data(zi, key; serialized, kwargs...)
end
function _wrap_load_data(zi::ZarrInstance, key; sz=nothing, serialized=false, kwargs...)
    # NOTE
    sz = serialized ? DEFAULT_CHUNK_SIZE : @something sz DEFAULT_CHUNK_SIZE
    @ifdebug @assert all(sz .> 0)
    try
        _load_data(zi, key, sz; kwargs..., serialized)
    catch e
        if typeof(e) ∈ (MethodError, ArgumentError)
            @error "load data error: " exception = e
            delete!(zi.store, key; recursive=true) # ensure path does not exist
            type = serialized ? Vector{UInt8} : get(kwargs, :type, Float64)
            emptyz = zcreate(
                type,
                zi.store,
                sz;
                fill_value=default_value(type),
                fill_as_missing=false,
                path=key,
                compressor,
            )
            _addkey!(zi, emptyz)
            if get(kwargs, :as_z, false)
                return (; z=emptyz, startstop=(0, 0))
            elseif get(kwargs, :with_z, false)
                return (; data=nothing, z=emptyz)
            else
                return nothing
            end
        else
            rethrow(e)
        end
    end
end
load_data(key::AbstractString; kwargs...) = load_data(zinstance(), key; kwargs...)

function _load_data(
    zi::ZarrInstance,
    key,
    sz=(100, 2);
    from="",
    to="",
    z_col=1,
    type=Float64,
    serialized=false,
    as_z=false,
    with_z=false,
)
    @debug "Loading data from $(zi.path):$(key)"
    z_type = serialized ? Vector{UInt8} : type
    za, existing = _get_zarray(zi, key, sz; overwrite=true, type=z_type, reset=false)
    ndims = length(sz)
    def_type = serialized ? Any : type
    function result(sz=tuple(0 for _ in 1:ndims)...; data=nothing, startstop=(0, 0))
        isnothing(data) && (data = Array{def_type,ndims}(undef, sz...))
        as_z && return (; z=za, startstop)
        with_z && return (; data, z=za)
        return data
    end
    (!existing || isempty(za)) && return result((0, sz[2:end]...))

    @as from timefloat(from)
    @as to timefloat(to)

    @debug let saved_first_ts = timefloat(za[begin, z_col])
        "Saved data first timestamp is $(saved_first_ts |> dt)"
    end

    with_from = !iszero(from)
    with_to = !iszero(to)

    ts_start = if with_from
        searchsortedfirst(@view(za[:, z_col]), from; by=timefloat)
    else
        firstindex(za, z_col)
    end
    ts_stop = if with_to
        rev = @view(za[lastindex(za, 1):-1:firstindex(za, 1), z_col])
        searchsortedfirst(rev, to; by=timefloat)
    else
        lastindex(za, z_col)
    end

    as_z && return result(; startstop=(ts_start, ts_stop))
    ts_start > size(za, 1) && return result()

    data = @view za[ts_start:ts_stop, :]

    with_from && @assert timefloat(data[begin, z_col]) >= from
    with_to && @assert timefloat(data[end, z_col]) <= to

    out = if serialized
        buf = IOBuffer()
        try
            first_time = todata(buf, data[begin, 1])
            first_val = todata(buf, data[begin, 2])
            first_el = (; time=first_time, value=first_val)
            this_type = typeof(first_el)
            def_val = default_value(this_type)
            out = Vector{this_type}(undef, size(data, 1))
            out[begin] = first_el
            foreach(Iterators.drop(firstindex(data, 1):size(data, 1), 1)) do n
                (;
                    time=todata(buf, data[n, 1]),
                    value=@something(todata(buf, data[n, 2]), def_val)
                )
            end
        finally
            close(buf)
        end
    else
        data
    end

    result(; data=out)
end

export save_data, load_data
