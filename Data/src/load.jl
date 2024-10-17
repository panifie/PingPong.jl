include("zarr_utils.jl")

using DataFrames: DataFrameRow, AbstractDataFrame
using DataFramesMeta
using .TimeTicks
using .Lang: Option, @as, @ifdebug
using Misc: LeftContiguityException, RightContiguityException, config, rangeafter

include("candles.jl")
include("ohlcv.jl")
include("pairdata.jl")
include("matrices.jl")
include("timedeltas.jl")

function nearestl2(n)
    log2 = round(log(n) / log(2))
    round(Int, 2^log2)
end

@doc """Choose chunk size depending on size of data with a predefined split (e.g. 1/100), padding to the nearest power of 2.

$(TYPEDSIGNATURES)
"""
function chunksize(data; parts=100, def=DEFAULT_CHUNK_SIZE[1])
    sz_rest = size(data)[2:end]
    n_rest = isempty(sz_rest) ? 1.0 : reduce(*, sz_rest)
    n = (size(data, 1) ÷ parts) * n_rest
    len = nearestl2(n) ÷ n_rest
    # If we multiply the size of all the dimensions we should get a number close to a power of 2
    (max(def, round(Int, len)), sz_rest...)
end

@doc """A custom exception representing a time frame error.

$(FIELDS)
"""
mutable struct TimeFrameError <: Exception
    first::Any
    last::Any
    td::Any
end

const SaveOHLCVError = Union{MethodError,DivideError,TimeFrameError}
function __handle_save_ohlcv_error(e::SaveOHLCVError, zi, key, pair, td, data; kwargs...)
    @warn "Resetting local data for pair $pair." e
    _save_ohlcv(zi, key, td, data; kwargs..., reset=true)
end
__handle_save_ohlcv_error(e, args...; kwargs...) = rethrow(e)

@doc """Save OHLCV data to a ZArray.

$(TYPEDSIGNATURES)

- `data_col`: The column index of the timestamp data in the input `data`. Default is 1.
- `saved_col`: The column index of the timestamp data in the existing data. Default is equal to `data_col`.
- `type`: The primitive type used for storing the data. Default is `Float64`.
- `existing`: A flag indicating whether existing data should be considered during the save operation. Default is `true`.
- `overwrite`: A flag indicating whether existing data should be overwritten during the save operation. Default is `true`.
- `reset`: A flag indicating whether the ZArray should be reset before saving the data. Default is `false`.
- `check`:
  - `:bounds` (default) only checks that new data is adjacent to previous data.
  - `:all` checks full contiguity of previous and new data.
  - `:none` or anything else, no checks are done.

The _save_ohlcv function saves OHLCV data to a ZArray. It performs checks on the input data and existing data (if applicable) to ensure contiguity and validity. If the checks pass, it calculates the offset based on the time difference between the first timestamps of the new and existing data. Then, it updates the ZArray with the new data starting at the calculated offset. The function provides various optional parameters to customize the save operation, such as handling existing data, overwriting, resetting, and performing checks.
"""
function save_ohlcv(zi::ZarrInstance, exc_name, pair, timeframe, data; kwargs...)
    @as_td
    @assert !isempty(exc_name) "No exchange name provided"
    key = key_path(exc_name, pair, timeframe)
    try
        _save_ohlcv(zi, key, td, data; kwargs...)
    catch e
        __handle_save_ohlcv_error(e, zi, key, pair, td, data; kwargs...)
    end
end
function save_ohlcv(zi::Ref{Option{ZarrInstance}}, args...; kwargs...)
    save_ohlcv(zi[], args...; kwargs...)
end

@doc "Default `ZArray` chunk size."
const OHLCV_CHUNK_SIZE = (2730, OHLCV_COLUMNS_COUNT)
const check_bounds_flag = :bounds
const check_all_flag = :all
const check_flags = (check_bounds_flag, check_all_flag)

function _save_ohlcv(
    za::ZArray,
    td,
    data;
    data_col=1,
    saved_col=data_col,
    type=Float64,
    existing=true,
    overwrite=true,
    reset=false,
    check=check_bounds_flag,
)
    isempty(data) && return nothing
    !reset && @check_td(data)

    if !reset && existing && size(za, 1) > 0
        local data_view
        saved_first_ts = za[begin, saved_col]
        saved_last_ts = za[end, saved_col]
        data_first_ts = timefloat(data[1, data_col])
        data_last_ts = timefloat(data[end, data_col])
        check ∈ check_flags && _check_contiguity(
            data_first_ts, data_last_ts, saved_first_ts, saved_last_ts, td
        )
        # if appending data
        if data_first_ts >= saved_first_ts
            if overwrite
                # when overwriting get the index where data starts overwriting storage
                # we count the number of candles using the difference
                offset = round(Int, ((data_first_ts - saved_first_ts + td) ÷ td), RoundDown)
                data_view = @view data[:, :]
                @debug "data: overwrite" timeframe = compact(Millisecond(td)) first_date = dt(data_first_ts) last_date = dt(saved_last_ts) next_date = dt(saved_last_ts + td)
                let end_date = if size(za, 1) < offset
                        za[end, saved_col]
                    else
                        @debug "data" saved = dt(za[end, saved_col]) data_first = dt(data[begin, data_col]) saved_off = dt(za[offset, data_col])
                        za[offset, saved_col]
                    end |> timefloat
                    @assert timefloat(data[begin, data_col]) >= end_date
                end
            else
                # when not overwriting get the index where data has new values
                data_range = rangeafter(@view(data[:, data_col]), saved_last_ts)
                data_offset = data_range.start
                offset = size(za, 1) + 1
                data_view = @view(data[data_range, :])
                @debug :saved, dt(za[end, saved_col]), dt(data[data_offset, data_col])
                @assert length(data_range) < 1 ||
                        za[end, saved_col] + td == timefloat(data[data_offset, data_col])
            end
            szdv = size(data_view, 1)
            if szdv > 0
                resize!(za, (offset - 1 + szdv, size(za, 2)))
                za[offset:end, :] = @to_mat(data_view)
            end
            @debug "Size data_view: " szdv
            # inserting requires overwrite
        else
            # fetch the saved data and combine with new one
            # fetch saved data starting after the last date of the new data
            # which has to be >= saved_first_date because we checked for contig
            saved_offset = Int(max(1, (data_last_ts - saved_first_ts + td) ÷ td))
            saved_data = za[(saved_offset+1):end, :]
            szd = size(data, 1)
            ssd = size(saved_data, 1)
            n_cols = size(za, 2)
            @debug ssd + szd, n_cols
            # the new size will include the amount of saved date not overwritten by new data plus new data
            resize!(za, (ssd + szd, n_cols))
            za[(szd+1):end, :] = saved_data
            za[begin:szd, :] = @to_mat(data)
            @debug :data_last, dt(data_last_ts) :saved_first, dt(saved_first_ts)
        end
    else
        let m = @to_mat(data)
            resize!(za, size(data))
            za[:, :] = m
        end
    end
    check == check_all_flag && begin
        @debug "Ensuring contiguity in saved data $(size(za))."
        _contiguous_ts(@view(za[:, saved_col]), td)
    end
    return za
end

function _save_ohlcv(
    zi::ZarrInstance,
    key,
    td,
    data;
    overwrite=true,
    reset=false,
    type=Float64,
    chunk_size=nothing,
    input=nothing,
    kwargs...,
)
    local za
    if !(input isa ZArray)
        za, existing = _get_zarray(
            zi, key, @something(chunk_size, chunksize(data)); type, overwrite, reset
        )
    else
        za, existing = input, true
    end
    @debug "Zarr dataset for key $key, len: $(size(data))."
    _save_ohlcv(za, td, data; overwrite, existing, reset, type, kwargs...)
end

@doc "Normalizes or special characthers separators to `_`.

$(TYPEDSIGNATURES)
"
@inline snakecased(pair::AbstractString) = replace(pair, r"\.|\/|\-" => "_")

@doc "The full key of the data stored for the (exchange, pair, timeframe) combination.

$(TYPEDSIGNATURES)
"
@inline function key_path(exc_name, pair, timeframe)
    # ensure no key path constructed starts with `/`
    # otherwise ZGroup creation does not halt
    isempty(exc_name) && (exc_name = "unknown")
    "$exc_name/$(snakecased(pair))/ohlcv/tf_$timeframe"
end

@doc "An empty OHLCV dataframe."
function empty_ohlcv()
    @debug "data: empty ohlcv" @caller(20)
    DataFrame(
        [DateTime[], [Float64[] for _ in OHLCV_COLUMNS_TS]...],
        OHLCV_COLUMNS;
        copycols=false,
    )
end

function _load_pairdata(out::Dict, k, zi, exc_name, timeframe; kwargs...)
    (pair_df, za) = load(zi, exc_name, k, timeframe; with_z=true, kwargs...)
    out[k] = PairData(k, timeframe, pair_df, za)
end

function _load_zarr(out::Dict, k, zi, exc_name, timeframe; kwargs...)
    (out[k], _) = load(zi, exc_name, k, timeframe; as_z=true, kwargs...)
end

@doc """Load OHLCV data from a ZarrInstance.

$(TYPEDSIGNATURES)

- `raw`: A flag indicating whether to return the raw data or process it into an OHLCV format. Default is `false`.
- `from`: The starting timestamp (inclusive) for loading data. Default is an empty string, indicating loading from the beginning of the ZArray.
- `to`: The ending timestamp (exclusive) for loading data. Default is an empty string, indicating loading until the end of the ZArray.
- `saved_col`: The column index of the timestamp data in the ZArray. Default is 1.
- `as_z`: A flag indicating whether to return the loaded data as a ZArray. Default is `false`.
- `with_z`: A flag indicating whether to return the loaded data along with the ZArray object. Default is `false`.

This function is used to load OHLCV data from a ZarrInstance. It takes in the ZarrInstance `zi`, the exchange name `exc_name`, the currency pairs `pairs`, and the timeframe. Optional parameters `raw` and `kwargs` can be specified to customize the loading process.
"""
function load_ohlcv(
    zi::ZarrInstance, exc_name::AbstractString, pairs, timeframe; raw=false, kwargs...
)
    out = Dict{String,raw ? ZArray : PairData}()
    load_func = raw ? _load_zarr : _load_pairdata
    pairs isa AbstractString && (pairs = [pairs])
    @sync for p in pairs
        @async load_func(out, p, zi, exc_name, timeframe; kwargs...)
    end
    out
end
function load_ohlcv(zi::ZarrInstance, exc, args...; kwargs...)
    load_ohlcv(zi, exc.name, args...; kwargs...)
end
function load_ohlcv(pair::AbstractString, args...; kwargs...)
    load_ohlcv([pair], args...; kwargs...)
end

const ResetErrors = Union{MethodError,DivideError,ArgumentError}
function __handle_error(::ResetErrors, zi, key, kwargs)
    delete!(zi.store, key; recursive=true) # ensure path does not exist
    emptyz = zcreate(
        Float64,
        zi.store,
        2,
        length(OHLCV_COLUMNS);
        fill_value=0.0,
        fill_as_missing=false,
        path=key,
        compressor,
    )
    _addkey!(zi, emptyz)
    if get(kwargs, :as_z, false)
        return emptyz, (0, 0)
    elseif get(kwargs, :with_z, false)
        return empty_ohlcv(), emptyz
    else
        return empty_ohlcv()
    end
end
__handle_error(e, args...) = rethrow(e)

function _wrap_load(zi::ZarrInstance, key::String, td::Float64; kwargs...)
    try
        _load_ohlcv(zi, key, td; kwargs...)
    catch e
        __handle_error(e, zi, key, kwargs)
    end
end
function _wrap_load(zi::Ref{Option{ZarrInstance}}, args...; kwargs...)
    _wrap_load(zi[], args...; kwargs...)
end

@doc "Load a pair ohlcv data from storage.
`as_z`: returns the ZArray
"
function load(zi::ZarrInstance, exc_name, pair, timeframe; raw=false, kwargs...)
    @as_td
    key = key_path(exc_name, pair, timeframe)
    _wrap_load(zi, key, timefloat(tf); as_z=raw, kwargs...)
end

load(zi::Ref{Option{ZarrInstance}}, args...; kwargs...) = load(zi[], args...; kwargs...)
function load_ohlcv(zi::Ref{Option{ZarrInstance}}, args...; kwargs...)
    load_ohlcv(zi[], args...; kwargs...)
end

@doc "Convert raw ccxt OHLCV data (matrix) to a dataframe."
function to_ohlcv(data::Matrix)
    # ccxt timestamps in milliseconds
    dates = unix2datetime.(@view(data[:, 1]) / 1e3)
    DataFrame(
        :timestamp => dates,
        (
            OHLCV_COLUMNS_TS[n] => @view(data[:, n+1]) for
            n in eachindex(OHLCV_COLUMNS_TS)
        )...;
        copycols=false,
    )
end

@doc "Construct a `DataFrame` without copying."
df!(args...; kwargs...) = DataFrame(args...; copycols=false, kwargs...)

function __ensure_ohlcv_zarray(zi, key)
    function get(reset)
        _get_zarray(zi, key, OHLCV_CHUNK_SIZE; overwrite=true, type=Float64, reset)[1]
    end
    z = get(false)
    z.metadata.fill_value isa Float64 && return z
    get(true)
end

@doc """ Load ohlcv pair data from zarr instance.
`za`: The zarr array holding the data
`key`: the name of the array to load from the zarr instance (in the format exchange/timeframe/pair)
`td`: the timeframe (as integer in milliseconds) of the target ohlcv table to be loaded
`from`, `to`: date range
"""
function _load_ohlcv(za::ZArray, td; from="", to="", saved_col=1, as_z=false, with_z=false)
    as_empty(start=0, stop=0) = begin
        as_z && return za, (start, stop)
        with_z && return (empty_ohlcv(), za)
        return empty_ohlcv()
    end

    if size(za, 1) < 2
        return as_empty()
    end

    @as from timefloat(from)
    @as to timefloat(to)

    saved_first_ts = za[begin, saved_col]
    @debug "Saved data first timestamp is $(saved_first_ts |> dt)"

    with_from = !iszero(from)
    with_to = !iszero(to)

    ts_start = if with_from
        min_idx = firstindex(za, saved_col)
        from_idx = (from - saved_first_ts + td) ÷ td
        @debug "data: with from" min_idx from_idx dt(from)
        round(Int, max(min_idx, from_idx))
    else
        firstindex(za, saved_col)
    end
    ts_stop = if with_to
        max_idx = lastindex(za, saved_col)
        to_idx = (ts_start + ((to - from) ÷ td))
        @debug "data: with to" max_idx to_idx dt(to)
        round(Int, min(max_idx, to_idx))
    else
        lastindex(za, saved_col)
    end

    if as_z
        return za, (ts_start, ts_stop)
    elseif isempty(ts_start:ts_stop)
        return as_empty(ts_start, ts_stop)
    end

    data = za[ts_start:ts_stop, :]

    if with_from && !(data[begin, saved_col] >= apply(td, timefloat(from)) - td)
        @warn "data: storage likely has missing entries, consider purging (begin)"
    end
    if with_to && !(data[end, saved_col] <= apply(td, timefloat(to)) + td)
        @warn "data: storage likely has missing entries, consider purging (end)"
    end

    (from_saved, to_saved) = (data[begin, saved_col], data[end, saved_col])
    if from_saved == to_saved && iszero(from_saved)
        delete!(za)
        as_empty()
    elseif with_z
        (to_ohlcv(data), za)
    else
        to_ohlcv(data)
    end
end
function _load_ohlcv(zi::ZarrInstance, key, args...; kwargs...)
    @debug "Loading data from $(zi.path):$(key)"
    za = __ensure_ohlcv_zarray(zi, key)
    _load_ohlcv(za, args...; kwargs...)
end
function _load_ohlcv(zi::Ref{Option{ZarrInstance}}, args...; kwargs...)
    _load_ohlcv(zi[], args...; kwargs...)
end

@doc """Check if a time series is contiguous based on a specified timeframe.

$(TYPEDSIGNATURES)

This function is used to check if a time series is contiguous based on a specified timeframe. It takes in the `series` as the input time series and the `timeframe` as a string representing the timeframe (e.g., "1h", "1d"). Optional parameters `raise` and `return_date` can be specified to customize the behavior of the function.

- `raise`: A flag indicating whether to raise a `TimeFrameError` if the time series is not contiguous. Default is `true`.
- `return_date`: A flag indicating whether to return the first non-contiguous date found in the time series. Default is `false`.
"""
function contiguous_ts(series, timeframe::AbstractString; raise=true, return_date=false)
    @as_td
    _contiguous_ts(series, td; raise, return_date)
end

function _contiguous_ts(
    series::AbstractVector{T}, td; raise=true, return_date=false
) where {T}
    pv = dtfloat(series[1])
    conv = T isa AbstractFloat ? identity : dtfloat
    for i in 2:length(series)
        nv = conv(series[i])
        nv - pv !== td && (
            if raise
                throw("Time series is not contiguous at index $i. ($(dt(pv)) != $(dt(nv)))")
            else
                return ifelse(return_date, (false, i, pv), false)
            end
        )
        pv = nv
    end
    return ifelse(return_date, (true, lastindex(series), pv), true)
end

@doc """Check the contiguity of timestamps between data and saved data.

$(TYPEDSIGNATURES)

Used to check the contiguity of timestamps between the data and saved data. It takes in the first and last timestamps of the data (`data_first_ts` and `data_last_ts`) and the first and last timestamps of the saved data (`saved_first_ts` and `saved_last_ts`).
Typically used as a helper function within the context of saving or loading OHLCV data to ensure the contiguity of timestamps.
"""
function _check_contiguity(
    data_first_ts::AbstractFloat,
    data_last_ts::AbstractFloat,
    saved_first_ts::AbstractFloat,
    saved_last_ts::AbstractFloat,
    td,
)
    data_first_ts > saved_last_ts + td &&
        throw(RightContiguityException(dt(saved_last_ts), dt(data_first_ts)))
    data_first_ts < saved_first_ts &&
        data_last_ts + td < saved_first_ts &&
        throw(LeftContiguityException(dt(saved_last_ts), dt(data_first_ts)))
end

export ZarrInstance, zinstance, PairData
export df!, @as_mat, @to_mat
export load, load_ohlcv, save_ohlcv
