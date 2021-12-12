using DataFrames
using Tables
using Zarr: is_zarray
using TimeFrames: TimeFrame

@doc "(Right)Merge two dataframes on key, assuming the key is ordered and unique in both dataframes."
function combinerows(df1, df2; idx::Symbol)
    # all columns
    columns = union(names(df1), names(df2))
    empty_tup2 = (;zip(Symbol.(names(df2)), Array{Missing}(missing, size(df2)[2]))...)
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
        empty_tup1 = (;zip(Symbol.(names(df1)), Array{Missing}(missing, size(df1)[2]))...)
        for r2 in Tables.namedtupleiterator(df2[c2:end, :])
            push!(rows, merge(empty_tup1, r2))
        end
    end
    DataFrame(rows)
end


macro zkey()
    p = esc(:pair)
    tf = esc(:timeframe)
    key = esc(:key)
    quote
        $key = joinpath($p, "ohlcv", "tf_" * $tf)
    end
    # joinpath("/", pair, "ohlcv", "tf_$timeframe")
end

function tfperiod(s::AbstractString)
    # convert m for minutes to T
    TimeFrame(replace(s, r"([0-9]+)m" => s"\1T")).period
end

function tfnum(prd::Dates.Period)
    convert(Dates.Millisecond, prd) |> x -> convert(Float64, x.value)
end

@doc """
`data_col`: the timestamp column of the new data (1)
`saved_col`: the timestamp column of the existing data (1)
`kind`: what type of trading data it is, (ohlcv or trades)
`pair`: the trading pair (BASE/QUOTE string)
`timeframe`: exchange timeframe (from exc.timeframes)
`type`: Primitive type used for storing the data (Float64)
"""
function _save(zi::ZarrInstance, pair, timeframe, data; kind="ohlcv", type=Float64, data_col=1, saved_col=1, overwrite=true, reset=false)
    @zkey
    prd = tfperiod(timeframe)
    td = tfnum(prd)
    local za
    local existing=true
    if is_zarray(zi.store, key)
        za = zopen(zi.store, "w"; path=key)
        if size(za, 2) !== size(data, 2)
            if overwrite
                rm(joinpath(zi.store.folder, key); recursive=true)
                za = zcreate(type, zi.store, size(data)...; path=key)
            else
                throw("Dimensions mismatch between stored data $(size(za)) and new data. $(size(data))")
            end
        else
            existing = true
        end
    else
        if !Zarr.isemptysub(zi.store, key)
            p = joinpath(zi.store.folder, key)
            @debug "Deleting garbage at path $p"
            rm(p; recursive=true)
        end
        za = zcreate(type, zi.store, size(data)...; path=key)
    end
    @debug "Zarr dataset for key $key, len: $(size(data))."
    if !reset && existing && size(za, 1) > 0
        local data_view
        saved_first_ts = za[1, saved_col]
        saved_last_ts = za[end, saved_col]
        data_first_ts = data[1, data_col]
        data_last_ts = data[end, data_col]
        _check_contiguity(data_first_ts, data_last_ts, saved_first_ts, saved_last_ts, td)
        # if appending data
        if data_first_ts >= saved_first_ts
            if overwrite
                # when overwriting get the index where data starts overwriting storage
                # we count the number of candles using the difference
                offset = convert(Int, ((data_first_ts - saved_first_ts + td) ÷ td))
                data_view = @view data[:, :]
                @debug dt(data_first_ts), dt(saved_last_ts), dt(saved_last_ts + td)
                @debug :saved, dt.(za[end, saved_col]) :data, dt.(data[1, data_col]) :saved_off, dt(za[offset, data_col])
                @assert data[1, data_col] === za[offset, saved_col]
            else
                # when not overwriting get the index where data has new values
                data_offset = searchsortedlast(data[:, data_col], saved_last_ts) + 1
                offset = size(za, 1) + 1
                if data_offset <= size(data, 1)
                    data_view = @view data[data_offset:end, :]
                    @debug :saved, dt(za[end, saved_col]) :data_new, dt(data[data_offset, data_col])
                    @assert za[end, saved_col] + td === data[data_offset, data_col]
                else
                    data_view = @view data[1:0, :]
                end
            end
            szdv = size(data_view, 1)
            if szdv > 0
                resize!(za, (offset - 1 + szdv, size(za, 2)))
                za[offset:end, :] = data_view[:, :]
                @debug _contiguous_ts(za[:, saved_col], td)
            end
            @debug "Size data_view: " szdv
        # inserting requires overwrite
        else
        # fetch the saved data and combine with new one
        # fetch saved data starting after the last date of the new data
        # which has to be >= saved_first_date because we checked for contig
            saved_offset = Int(max(1, (data_last_ts - saved_first_ts + td) ÷ td))
            saved_data = @view za[saved_offset + 1:end, :]
            szd = size(data, 1)
            ssd = size(saved_data, 1)
            n_cols = size(za, 2)
            @debug ssd + szd, n_cols
            # the new size will include the amount of saved date not overwritten by new data plus new data
            resize!(za, (ssd + szd, n_cols))
            za[szd + 1:end, :] = saved_data[:, :]
            za[begin:szd, :] = data[:, :]
            @debug :data_last, dt(data_last_ts) :saved_first, dt(saved_first_ts)
        end
        @debug "Ensuring contiguity in saved data $(size(za))." _contiguous_ts(za[:, data_col], td)
    else
        offset = 0
        resize!(za, size(data))
        za[:, :] = data[:, :]
    end
    return za
end

macro as(sym, val)
    s = esc(sym)
    v = esc(val)
    quote
        $s = $v
        true
    end
end

macro check_td()
    za = esc(:za)
    col = esc(:saved_col)
    td = esc(:td)
    quote
        @assert $za[2, $col] - $za[1, $col] === $td
    end
end

function _load(zi, pair, timeframe="1m"; from="", to="", saved_col=1)
    @zkey
    za = zopen(zi.store, "w"; path=key)
    if size(za, 1) === 0
        return DataFrame(Matrix(undef, 0, length(OHLCV_COLUMNS)), OHLCV_COLUMNS)
    end
    prd = tfperiod(timeframe)
    td = tfnum(prd)
    @check_td

    @as from timefloat(from)
    @as to timefloat(to)

    saved_first_ts = za[begin, saved_col]

    with_from = !isnothing(from)
    with_to = !isnothing(to)
    if with_from
        ts_start = max(1, (from - saved_first_ts + td) ÷ td) |> Int
    else
        ts_start = firstindex(za, 1)
    end
    if with_to
        ts_stop = (ts_start + ((to - from) ÷ td)) |> Int
    else
        ts_stop = lastindex(za, 1)
    end
    data = za[ts_start:ts_stop, :]

    with_from && @assert data[begin, saved_col] >= from
    with_to && @assert data[end, saved_col] <= to

    return to_df(data)
end

function dt(num::Real)
    Dates.unix2datetime(num / 1e3)
end

function dtfloat(d::DateTime)::AbstractFloat
    Dates.datetime2unix(d) * 1e3
end

function timefloat(time::AbstractFloat)
    time
end

function timefloat(time::DateTime)
    dtfloat(time)
end

function timefloat(time::String)
    time === "" && return dtfloat(dt(0))
    DateTime(time) |> dtfloat
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

contiguous_ts(series, timeframe::AbstractString) = begin
    @astd
    _contiguous_ts(series, td)
end

function _contiguous_ts(series::AbstractVector{AbstractFloat}, td::AbstractFloat)
    pv = series[1]
    for i in 2:length(series)
        nv = series[i]
        nv - pv !== td && throw("Time series is not contiguous at index $i.")
        pv = nv
    end
    true
end

function _check_contiguity(data_first_ts, data_last_ts, saved_first_ts, saved_last_ts, td)
    data_first_ts > saved_last_ts + td &&
        throw("Data stored ends at $(dt(saved_last_ts)) while new data starts at $(dt(data_first_ts)). Data must be contiguous.")
    data_first_ts < saved_first_ts && data_last_ts + td < saved_first_ts &&
        throw("Data stored starts at $(dt(saved_first_ts)) while new data ends at $(dt(data_last_ts)). Data must be contiguous.")
end

macro astd()
    tf = esc(:timeframe)
    td = esc(:td)
    prd = esc(:prd)
    quote
        $prd = tfperiod($tf)
        $td = tfnum($prd)
    end
end

struct Candle
    timestamp::DateTime
    open::Real
    high::Real
    low::Real
    close::Real
    volume::Real
end

using DataFramesMeta

@doc """Assuming timestamps are sorted, returns a new dataframe with a contiguous rows based on timeframe.
Rows are filled either by previous close, or NaN. """
fill_missing_rows(df, timeframe::AbstractString; strategy=:close) = begin
    @astd
    _fill_missing_rows(df, prd; strategy, inplace=false)
end

fill_missing_rows!(df, timeframe::AbstractString; strategy=:close) = begin
    @astd
    _fill_missing_rows(df, prd; strategy, inplace=true)
end

function _fill_missing_rows(df, prd::Period; strategy, inplace)
    let ordered_rows = []
        # fill the row by previous close or with NaNs
        can = strategy === :close ? (x) -> [x, x, x, x, 0] : (_) -> [NaN, NaN, NaN, NaN, NaN]
        @with df begin
            ts_cur, ts_end = first(:timestamp) + prd, last(:timestamp)
            ts_idx = 2
            while ts_cur < ts_end
                if ts_cur !== :timestamp[ts_idx]
                    close = :close[ts_idx - 1]
                    push!(ordered_rows, Candle(ts_cur, can(close)...))
                else
                    ts_idx += 1
                end
                ts_cur += prd
            end
        end
        inplace || (df = deepcopy(df); true)
        append!(df, ordered_rows)
        sort!(df, :timestamp)
        return df
    end
end

using DataFrames: groupby, combine
@doc """Similar to the freqtrade homonymous function.
`fill_missing`: `:close` fills non present candles with previous close and 0 volume, else with `NaN`.
"""
function cleanup_ohlcv_data(data, timeframe; col=1, fill_missing=:close)
    df = data isa DataFrame ? data : to_df(data)
    gd = groupby(df, :timestamp; sort=true)
    df = combine(gd, :open => first, :high => maximum, :low => minimum, :close => last, :volume => maximum; renamecols=false)
    @astd

    if is_incomplete_candle(df[end, :], td)
        last_candle = copy(df[end, :])
        delete!(df, lastindex(df, 1))
        @info "Dropping last candle ($(last_candle[:timestamp])) because it is incomplete."
    end
    return df
    if fill_missing !== false
        fill_missing_rows!(df, prd; strategy=fill_missing)
    end
    df
end

function is_incomplete_candle(candle, td::AbstractFloat)
    ts = timefloat(candle.timestamp)
    now = timefloat(Dates.now(Dates.UTC))
    ts + td > now
end

function is_incomplete_candle(candle, timeframe="1m")
    @astd
    is_incomplete_candle(candle, td)
end

macro df(v)
    quote
        to_df($(esc(v)))
    end
end

# function apply(grp::GroupBy)
#     apply(grp.action)
# end

# function apply(resampler::TimeArrayResampler, f::Function)
#     dt_grouper(resampler.tf, eltype(timestamp(resampler.ta)))
#     f_group = dt_grouper(resampler.tf, eltype(timestamp(resampler.ta)))
#     @show f_group
#     collapse(resampler.ta, f_group, dt -> f_group(first(dt)), f)
# end

export @df
