using Requires

include("zarr_utils.jl")

using DataFrames: DataFrameRow, AbstractDataFrame
using DataFramesMeta
using TimeTicks
using Lang: @as, @ifdebug
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

@doc "Choose chunk size depending on size of data with a predefined split (e.g. 1/100), padding to the nearest power of 2."
function chunksize(data; parts=100, def=DEFAULT_CHUNK_SIZE[1])
    sz_rest = size(data)[2:end]
    n_rest = reduce(*, sz_rest)
    n = (size(data, 1) ÷ parts) * n_rest
    len = nearestl2(n) ÷ n_rest
    # If we multiply the size of all the dimensions we should get a number close to a power of 2
    (max(def, round(Int, len)), sz_rest...)
end

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

@doc """
`data_col`: the timestamp column of the new data (1)
`saved_col`: the timestamp column of the existing data (1)
`pair`: the trading pair (BASE/QUOTE string)
`timeframe`: exchange timeframe (from exc.timeframes)
`type`: Primitive type used for storing the data (Float64)
`check`:
  - `:bounds` (default) only checks that new data is adjacent to previous data.
  - `:all` checks full contiguity of previous and new data.
  - `:none` or anything else, no checks are done.
"""
function save_ohlcv(zi::ZarrInstance, exc_name, pair, timeframe, data; kwargs...)
    @as_td
    @assert !isempty(exc_name) "No exchange name provided"
    key = key_path(exc_name, pair, timeframe)
    try
        t = @async _save_ohlcv(zi, key, td, data; kwargs...)
        fetch(t)
    catch e
        __handle_save_ohlcv_error(e, zi, key, pair, td, data; kwargs...)
    end
end
save_ohlcv(zi::Ref{ZarrInstance}, args...; kwargs...) = save_ohlcv(zi[], args...; kwargs...)

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
                offset = convert(Int, ((data_first_ts - saved_first_ts + td) ÷ td))
                data_view = @view data[:, :]
                @debug begin
                    ts = compact(Millisecond(td))
                    first_date = dt(data_first_ts)
                    last_date = dt(saved_last_ts)
                    next_date = dt(saved_last_ts + td)
                    "timeframe: $ts\nfirst_date: $first_date\nlast_date: $last_date\nnext_date: $next_date"
                end
                @debug begin
                    saved = dt(za[end, saved_col])
                    data_first = dt(data[begin, data_col])
                    saved_off = dt(za[offset, data_col])
                    "saved: $saved\ndata_first: $data_first\nsaved_off: $saved_off"
                end
                @assert timefloat(data[begin, data_col]) >= timefloat(za[offset, saved_col])
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

@doc "Normalizes or special characthers separators to `_`."
@inline snakecased(pair::AbstractString) = replace(pair, r"\.|\/|\-" => "_")

@doc "The full key of the data stored for the (exchange, pair, timeframe) combination."
@inline function key_path(exc_name, pair, timeframe)
    # ensure no key path constructed starts with `/`
    # otherwise ZGroup creation does not halt
    isempty(exc_name) && (exc_name = "unknown")
    "$exc_name/$(snakecased(pair))/ohlcv/tf_$timeframe"
end

@doc "An empty OHLCV dataframe."
function empty_ohlcv()
    DataFrame(
        [DateTime[], [Float64[] for _ in OHLCV_COLUMNS_TS]...],
        OHLCV_COLUMNS;
        copycols=false,
    )
end

function _load_pairdata(out::Dict, k, zi, exc_name, timeframe)
    (pair_df, za) = load(zi, exc_name, k, timeframe; with_z=true)
    out[k] = PairData(k, timeframe, pair_df, za)
end

function _load_zarr(out::Dict, k, zi, exc_name, timeframe)
    (out[k], _) = load(zi, exc_name, k, timeframe; as_z=true)
end

@doc "Load data from given zarr instance, exchange, pairs list and timeframe."
function load_ohlcv(zi::ZarrInstance, exc_name::AbstractString, pairs, timeframe; raw=false)
    out = Dict{String,raw ? za.ZArray : PairData}()
    load_func = raw ? _load_zarr : _load_pairdata
    @sync for p in pairs
        @async load_func(out, p, zi, exc_name, timeframe)
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
    delete!(zi.store, key) # ensure path does not exist
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
    if :as_z ∈ keys(kwargs)
        return emptyz, (0, 0)
    elseif :with_z ∈ keys(kwargs)
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
_wrap_load(zi::Ref{ZarrInstance}, args...; kwargs...) = _wrap_load(zi[], args...; kwargs...)

@doc "Load a pair ohlcv data from storage.
`as_z`: returns the ZArray
"
function load(zi::ZarrInstance, exc_name, pair, timeframe; raw=false, kwargs...)
    @as_td
    key = key_path(exc_name, pair, timeframe)
    t = @async _wrap_load(zi, key, timefloat(tf); as_z=raw, kwargs...)
    fetch(t)
end

load(zi::Ref{ZarrInstance}, args...; kwargs...) = load(zi[], args...; kwargs...)

@doc "Convert raw ccxt OHLCV data (matrix) to a dataframe."
function to_ohlcv(data::Matrix)
    # ccxt timestamps in milliseconds
    dates = unix2datetime.(@view(data[:, 1]) / 1e3)
    DataFrame(
        :timestamp => dates,
        (
            OHLCV_COLUMNS_TS[n] => @view(data[:, n + 1]) for
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
    if size(za, 1) < 2
        as_z && return za, (0, 0)
        with_z && return (empty_ohlcv(), za)
        return empty_ohlcv()
    end

    @as from timefloat(from)
    @as to timefloat(to)

    saved_first_ts = za[begin, saved_col]
    @debug "Saved data first timestamp is $(saved_first_ts |> dt)"

    with_from = !iszero(from)
    with_to = !iszero(to)

    ts_start = if with_from
        Int(max(firstindex(za, saved_col), (from - saved_first_ts + td) ÷ td))
    else
        firstindex(za, saved_col)
    end
    ts_stop = if with_to
        Int(min(lastindex(za, saved_col), (ts_start + ((to - from) ÷ td))))
    else
        lastindex(za, saved_col)
    end

    as_z && return za, (ts_start, ts_stop)

    data = za[ts_start:ts_stop, :]

    with_from && @assert data[begin, saved_col] >= from
    with_to && @assert data[end, saved_col] <= to

    with_z && return (to_ohlcv(data), za)
    to_ohlcv(data)
end
function _load_ohlcv(zi::ZarrInstance, key, args...; kwargs...)
    @debug "Loading data from $(zi.path):$(key)"
    za = __ensure_ohlcv_zarray(zi, key)
    _load_ohlcv(za, args...; kwargs...)
end
function _load_ohlcv(zi::Ref{ZarrInstance}, args...; kwargs...)
    _load_ohlcv(zi[], args...; kwargs...)
end

@doc "Checks if a timeseries has any intervals not conforming to the given timeframe."
contiguous_ts(series, timeframe::AbstractString) = begin
    @as_td
    _contiguous_ts(series, td)
end

function _contiguous_ts(series::AbstractVector{T}, td; raise=true) where {T}
    pv = dtfloat(series[1])
    conv = T isa AbstractFloat ? identity : dtfloat
    for i in 2:length(series)
        nv = conv(series[i])
        nv - pv !== td && (
            if raise
                throw("Time series is not contiguous at index $i. ($(dt(pv)) != $(dt(nv)))")
            else
                return false
            end
        )
        pv = nv
    end
    return true
end

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

export ZarrInstance, zilmdb, PairData
export df!, @as_mat, @to_mat
export load, load_ohlcv, save_ohlcv
