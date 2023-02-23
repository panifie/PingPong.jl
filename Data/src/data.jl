using Requires

include("zarr_utils.jl")

using DataFrames: DataFrameRow
using DataFramesMeta
using TimeTicks
using Lang: @as
using Misc: LeftContiguityException, RightContiguityException, config, rangeafter

const OHLCV_COLUMNS = [:timestamp, :open, :high, :low, :close, :volume]
const OHLCV_COLUMNS_TS = setdiff(OHLCV_COLUMNS, [:timestamp])
const OHLCV_COLUMNS_NOV = setdiff(OHLCV_COLUMNS, [:timestamp, :volume])

struct Candle{T<:AbstractFloat}
    timestamp::DateTime
    open::T
    high::T
    low::T
    close::T
    volume::T
    Candle(args...; kwargs...) = begin
        new{Float64}(args...; kwargs...)
    end
    Candle(t::NamedTuple) = Candle(t...)
    Candle(t::Tuple) = Candle(t...)
end

@doc "Similar to a StructArray (and should probably be replaced by it), used for fast conversion."
const OHLCVTuple = Tuple{Vector{DateTime},Vararg{Vector{Float64},5}}
OHLCVTuple()::OHLCVTuple = (DateTime[], (Float64[] for _ in 2:length(OHLCV_COLUMNS))...)
Base.append!(a::T, b::T) where {T<:OHLCVTuple} = foreach(splat(append!), zip(a, b))
Base.axes(o::OHLCVTuple) = ((Base.OneTo(size(v, 1)) for v in o)...,)
Base.axes(o::OHLCVTuple, i) = Base.OneTo(size(o[i], 1))
Base.getindex(o::OHLCVTuple, i, j) = o[j][i]

@kwdef struct PairData
    name::String
    tf::String # string
    data::Union{Nothing,AbstractDataFrame} # in-memory data
    z::Union{Nothing,ZArray} # reference zarray
end

function Base.convert(
    ::Type{AbstractDict{String,N}}, d::AbstractDict{String,PairData}
) where {N<:AbstractDataFrame}
    Dict(p.name => p.data for p in values(d))
end

macro check_td(args...)
    local check_data
    if !isempty(args)
        check_data = esc(args[1])
    else
        check_data = esc(:za)
    end
    col = esc(:saved_col)
    td = esc(:td)
    quote
        if size($check_data, 1) > 1
            timeframe_match = timefloat($check_data[2, $col] - $check_data[1, $col]) == $td
            if !timeframe_match
                @warn "Saved date not matching timeframe, resetting."
                throw(
                    TimeFrameError(
                        string($check_data[1, $col]),
                        string($check_data[2, $col]),
                        convert(Second, Millisecond($td)),
                    ),
                )
            end
        end
    end
end

@doc "Redefines given variable to a Matrix with type of the underlying container type."
macro as_mat(data)
    tp = esc(:type)
    d = esc(data)
    quote
        # Need to convert to Matrix otherwise assignement throws dimensions mismatch...
        # this allocates...
        if !(typeof($d) <: Matrix{$tp})
            $d = Matrix{$tp}($d)
        end
    end
end

@doc "Same as `as_mat` but returns the new matrix."
macro to_mat(data, tp=nothing)
    if tp === nothing
        tp = esc(:type)
    else
        tp = esc(tp)
    end
    d = esc(data)
    quote
        # Need to convert to Matrix otherwise assignement throws dimensions mismatch...
        # this allocates...
        if !(typeof($d) <: Matrix{$tp})
            Matrix{$tp}($d)
        else
            $d
        end
    end
end

@doc "The time interval of the dataframe, guesses from the difference between the first two rows."
function data_td(data)
    @debug @assert size(data, 1) > 1 "Need a timeseries of at least 2 points to find a time delta."
    data.timestamp[2] - data.timestamp[1]
end

@doc "`combinerows` of two (OHLCV) dataframes over using `:timestamp` column as index."
function combine_data(prev, data)
    df1 = DataFrame(prev, OHLCV_COLUMNS; copycols=false)
    df2 = DataFrame(data, OHLCV_COLUMNS; copycols=false)
    combinerows(df1, df2; idx=:timestamp)
end

@doc "(Right)Merge two dataframes on key, assuming the key is ordered and unique in both dataframes."
function combinerows(df1, df2; idx::Symbol)
    # all columns
    columns = union(names(df1), names(df2))
    empty_tup2 = (; zip(Symbol.(names(df2)), Array{Missing}(missing, size(df2)[2]))...)
    l2 = size(df2)[1]

    c2 = 1
    i2 = df2[c2, idx]
    rows = []
    for (n, r1) in enumerate(Tables.namedtupleiterator(df1))
        i1 = getindex(r1, idx)
        if i1 < i2
            push!(rows, merge(empty_tup2, r1))
        elseif i1 === i2
            push!(rows, merge(r1, df2[c2, :]))
        elseif c2 < l2 # bring the df2 index to the df1 position
            c2 += 1
            i2 = df2[c2, idx]
            while i2 < i1 && c2 < l2
                c2 += 1
                i2 = df2[c2, idx]
            end
            i2 === i1 && push!(rows, merge(r1, df2[c2, :]))
        else # merge the rest of df1
            for rr1 in Tables.namedtupleiterator(df1[n:end, :])
                push!(rows, merge(empty_tup2, rr1))
            end
            break
        end
    end
    # merge the rest of df2
    if c2 < l2
        empty_tup1 = (; zip(Symbol.(names(df1)), Array{Missing}(missing, size(df1)[2]))...)
        for r2 in Tables.namedtupleiterator(df2[c2:end, :])
            push!(rows, merge(empty_tup1, r2))
        end
    end
    DataFrame(rows; copycols=false)
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
"""
function save_ohlcv(zi::ZarrInstance, exc_name, pair, timeframe, data; kwargs...)
    @as_td
    key = pair_key(exc_name, pair, timeframe)
    try
        t = @async _save_ohlcv(zi, key, td, data; kwargs...)
        fetch(t)
    catch e
        __handle_save_ohlcv_error(e, zi, key, pair, td, data; kwargs...)
    end
end
save_ohlcv(zi::Ref{ZarrInstance}, args...; kwargs...) = save_ohlcv(zi[], args...; kwargs...)
# _docopy(z, from, data, type) = z[from:end, :] = @to_mat(data)

function _save_ohlcv(
    zi::ZarrInstance,
    key,
    td,
    data;
    type=Float64,
    data_col=1,
    saved_col=data_col,
    overwrite=true,
    reset=false,
    check=false,
)
    local za
    !reset && @check_td(data)

    za, existing = _get_zarray(zi, key, size(data); type, overwrite, reset)

    @debug "Zarr dataset for key $key, len: $(size(data))."
    if !reset && existing && size(za, 1) > 0
        local data_view
        saved_first_ts = za[begin, saved_col]
        saved_last_ts = za[end, saved_col]
        data_first_ts = timefloat(data[1, data_col])
        data_last_ts = timefloat(data[end, data_col])
        _check_contiguity(data_first_ts, data_last_ts, saved_first_ts, saved_last_ts, td)
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
                # _docopy(za, offset, data_view, type)
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
        resize!(za, size(data))
        za[:, :] = @to_mat(data)
    end
    @debug "Ensuring contiguity in saved data $(size(za))."
    check && _contiguous_ts(@view(za[:, saved_col]), td)
    return za
end

@doc "Normalizes or special characthers separators to `_`."
@inline sanitize_pair(pair::AbstractString) = replace(pair, r"\.|\/|\-" => "_")

@doc "The full key of the data stored for the (exchange, pair, timeframe) combination."
@inline function pair_key(exc_name, pair, timeframe)
    "$exc_name/$(sanitize_pair(pair))/ohlcv/tf_$timeframe"
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
function load_ohlcv(zi::ZarrInstance, exc, pairs, timeframe; raw=false)
    exc_name = exc.name
    out = Dict{String,raw ? za.ZArray : PairData}()
    load_func = raw ? _load_zarr : _load_pairdata
    @sync for p in pairs
        @async load_func(out, p, zi, exc_name, timeframe)
    end
    out
end
load_ohlcv(pair::AbstractString, args...) = load_ohlcv([pair], args...)

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
    key = pair_key(exc_name, pair, timeframe)
    t = _wrap_load(zi, key, timefloat(tf); as_z=raw, kwargs...)
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

function to_ohlcv(data::AbstractVector{Candle}, timeframe::TimeFrame)
    df = DataFrame(data; copycols=false)
    df.timestamp[:] = apply.(timeframe, df.timestamp)
    df
end
to_ohlcv(v::OHLCVTuple) = DataFrame([v...], OHLCV_COLUMNS)

function __ensure_ohlcv_zarray(zi, key)
    ncols = length(OHLCV_COLUMNS)
    function get(reset)
        _get_zarray(zi, key, (2, ncols); overwrite=true, type=Float64, reset)[1]
    end
    z = get(false)
    z.metadata.fill_value isa Float64 && return z
    get(true)
end

@doc """ Load ohlcv pair data from zarr instance.
`zi`: The zarr instance to use
`key`: the name of the array to load from the zarr instance (in the format exchange/timeframe/pair)
`td`: the timeframe (as integer in milliseconds) of the target ohlcv table to be loaded
`from`, `to`: date range
"""
function _load_ohlcv(
    zi::ZarrInstance, key, td; from="", to="", saved_col=1, as_z=false, with_z=false
)
    @debug "Loading data from $(zi.path):$(key)"
    za = __ensure_ohlcv_zarray(zi, key)

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
function _load_ohlcv(zi::Ref{ZarrInstance}, args...; kwargs...)
    _load_ohlcv(zi[], args...; kwargs...)
end

function _contiguous_ts(series::AbstractVector{DateTime}, td::AbstractFloat)
    pv = dtfloat(series[1])
    for i in 2:length(series)
        nv = dtfloat(series[i])
        nv - pv !== td && throw("Time series is not contiguous at index $i.")
        pv = nv
    end
    true
end

@doc "Checks if a timeseries has any intervals not conforming to the given timeframe."
contiguous_ts(series, timeframe::AbstractString) = begin
    @as_td
    _contiguous_ts(series, td)
end

function _contiguous_ts(series::AbstractVector{Float64}, td::Float64)
    pv = series[1]
    for i in 2:length(series)
        nv = series[i]
        nv - pv !== td && throw("Time series is not contiguous at index $i.")
        pv = nv
    end
    true
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

@enum CandleField cdl_ts = 1 cdl_o = 2 cdl_h = 3 cdl_lo = 4 cdl_cl = 5 cdl_vol = 6

const CandleCol = (; timestamp=1, open=2, high=3, low=4, close=5, volume=6)

Base.convert(::Type{Candle}, row::DataFrameRow) = Candle(row...)

export PairData,
    ZarrInstance, zilmdb, @as_df, @as_mat, @to_mat, load, load_ohlcv, save_ohlcv
