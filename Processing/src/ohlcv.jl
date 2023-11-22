using .TimeTicks: Period, now, timeframe, apply
using Data.DataFramesMeta
using Data.DataFrames: clear_pt_conf!
using Data: Candle, to_ohlcv, empty_ohlcv, DFUtils, ZArray, _load_ohlcv, _save_ohlcv, zi
using Base: _cleanup_locked
using .DFUtils: appendmax!, lastdate

@doc """Fills missing candles in a DataFrame.

$(TYPEDSIGNATURES)

This function takes a DataFrame `df`, a string `timeframe`, and optionally a filling strategy `strategy`. It identifies the missing candles in `df` based on the `timeframe`, and fills them using the specified `strategy`.

filling strategies:

- `:close`: fill with the close price of the previous candle.
- `:open`: fill with the open price of the next candle.
- `:linear`: linearly interpolate between the close price of the previous candle and the open price of the next candle.

"""
function fill_missing_candles(df, timeframe::AbstractString; strategy=:close)
    @as_td
    _fill_missing_candles(df, prd; strategy, inplace=false)
end

@doc """$(TYPEDSIGNATURES) See [`fill_missing_candles`](@ref)."""
function fill_missing_candles!(df, prd::Period; strategy=:close)
    _fill_missing_candles(df, prd; strategy, inplace=true)
end

@doc """$(TYPEDSIGNATURES) See [`fill_missing_candles`](@ref)."""
function _fill_missing_candles!(df, timeframe::AbstractString; strategy=:close)
    @as_td
    _fill_missing_candles(df, prd; strategy, inplace=true)
end

_update_timestamps(left, prd, ts, from_idx) = begin
    for i in from_idx:lastindex(ts)
        left += prd
        ts[i] = left
    end
end

_check_cap(::Val{:uncapped}, args...) = nothing
function _check_cap(::Val{:capped}, df, cap)
    size(df, 1) > cap && popfirst!(df)
end
_append_cap!(::Val{:uncapped}, _, args...) = append!(args...)
_append_cap!(::Val{:capped}, cap, args...) = appendmax!(args..., cap)

@doc """Applies trailing operation on a DataFrame based on a time frame.

$(TYPEDSIGNATURES)

This function takes a DataFrame `df`, a TimeFrame `tf`, and optionally a timestamp `to`, a timestamp `from`, and a cap `cap`. It applies a trailing window operation on `df` for the specified `tf`. The operation starts from the timestamp specified by `from` (default is the last timestamp in the DataFrame) and ends at the timestamp specified by `to`. The `cap` argument determines the maximum number of rows to keep in the dataframe.

"""
function trail!(df, tf::TimeFrame; to, from=df[end, :timestamp], cap=0)
    prd = period(tf)
    n_to_append = (to - from) ÷ prd - 1
    if n_to_append > 0
        capval = cap > 0 ? Val(:capped) : Val(:uncapped)
        push!(df, @view(df[end, :]))
        _check_cap(capval, df, cap)
        from += prd
        close = df[end, :close]
        df[end, :timestamp] = from
        df[end, :open] = close
        df[end, :high] = close
        df[end, :low] = close
        df[end, :volume] = 0
        n_to_append -= 1
        if n_to_append > 0
            to_append = repeat(@view(df[end:end, :]), n_to_append)
            _append_cap!(capval, cap, df, to_append)
            from_idx = lastindex(df.timestamp) - n_to_append + 1
            _update_timestamps(from, prd, df.timestamp, from_idx)
        end
    end
end
novol_candle(ts, n) = Candle(ts, n, n, n, n, 0)
nan_candle(ts, _) = Candle(ts, NaN, NaN, NaN, NaN, NaN)

_isunixepoch(ts) = ts.instant.periods.value == TimeTicks.Dates.UNIXEPOCH
trimzeros!(df) = begin
    idx = 1
    for t in df.timestamp
        _isunixepoch(t) || break
        idx += 1
    end
    idx > 1 && deleteat!(df, 1:(idx - 1))
end

function _fill_missing_candles(
    df::DataFrame, prd::Period; strategy, inplace, def_strategy=nan_candle, def_type=Candle
)
    trimzeros!(df)
    size(df, 1) == 0 && return empty_ohlcv()
    ordered_rows = def_type[]
    # fill the row by previous close or with NaNs
    build_candle = ifelse(strategy == :close, novol_candle, def_strategy)
    @with df begin
        ts_cur, ts_end = first(:timestamp) + prd, last(:timestamp)
        ts_idx = 2
        # NOTE: we assume that ALL timestamps are multiples of the timedelta!
        while ts_cur < ts_end
            if ts_cur != :timestamp[ts_idx]
                close = :close[ts_idx - 1]
                push!(ordered_rows, build_candle(ts_cur, close))
            else
                ts_idx += 1
            end
            ts_cur += prd
        end
    end
    inplace || (df = deepcopy(df))
    try
        append!(df, ordered_rows)
    catch
        # In case the dataframe is backed by a matrix we have to copy
        df = DataFrame(df; copycols=true)
        append!(df, ordered_rows)
    end
    sort!(df, :timestamp)
    trimzeros!(df)
    return df
end

@doc """Removes incomplete candles from a DataFrame.

$(TYPEDSIGNATURES)

This function takes a DataFrame `in_df` and a TimeFrame `tf`. It identifies any incomplete candles in `in_df` based on `tf` and removes them.

See [`isincomplete`](@ref) for more information.
"""
function _remove_incomplete_candle(in_df, tf)
    df = in_df isa SubDataFrame ? copy(in_df) : in_df
    if isincomplete(df[end, :timestamp], tf)
        lastcandle = copy(df[end, :])
        deleteat!(df, lastindex(df, 1))
        @debug "Dropping last candle ($(lastcandle.timestamp |> string)) because it is incomplete."
    end
    df
end
@doc """Cleans up OHLCV data in a DataFrame.

$(TYPEDSIGNATURES)

This function takes a DataFrame `data`, a TimeFrame `tf`, and optionally a column index `col` and a filling strategy `fill_missing`. It cleans up the OHLCV data in `data` by removing any incomplete candles based on `tf`, filling any missing candles using the specified filling strategy, and sorting the data by the specified column.

"""
function cleanup_ohlcv_data(data, tf::TimeFrame; col=1, fill_missing=:close)
    @debug "Cleaning dataframe of size: $(size(data, 1))."
    size(data, 1) == 0 && return empty_ohlcv()
    df = data isa AbstractDataFrame ? data : to_ohlcv(data, tf)

    # remove incomplete candle before timestamp normalization
    df = _remove_incomplete_candle(df, tf)
    # normalize dates
    @eachrow! df begin
        :timestamp = apply(tf, :timestamp)
    end

    gd = groupby(df, :timestamp; sort=true)
    df = combine(
        gd,
        :open => first,
        :high => maximum,
        :low => minimum,
        :close => last,
        :volume => maximum;
        renamecols=false,
    )
    # check again after de-duplication
    df = _remove_incomplete_candle(df, tf)

    if fill_missing != false
        fill_missing_candles!(df, tf.period; strategy=fill_missing)
    else
        trimzeros!(df)
    end
    df
end
@doc """$(TYPEDSIGNATURES) See [`cleanup_ohlcv_data`](@ref)."""
function cleanup_ohlcv_data(data, tf::AbstractString; kwargs...)
    cleanup_ohlcv_data(data, convert(TimeFrame, tf); kwargs...)
end

@doc """Cleans up OHLCV data in a ZArray.

$(TYPEDSIGNATURES)

This function takes a ZArray `z` and a string `timeframe`. It cleans up the OHLCV data in `z` by removing any incomplete candles based on `timeframe` and filling any missing candles using the specified filling strategy.

"""
function cleanup_ohlcv!(z::ZArray, timeframe::AbstractString)
    tf = convert(TimeFrame, timeframe)
    ohlcv = _load_ohlcv(z, timeframe)
    ohlcv = cleanup_ohlcv_data(ohlcv, tf)
    _save_ohlcv(z::ZArray, timefloat(tf), ohlcv)
end

isincomplete(d::DateTime, tf::TimeFrame, ::Val{:raw}) = d + tf > now()
@doc """Checks if a DateTime is incomplete based on a TimeFrame.

$(TYPEDSIGNATURES)
"""
isincomplete(d::DateTime, tf::TimeFrame) = isincomplete(apply(tf, d), tf, Val(:raw))
@doc "Checks if a candle is too new.

$(TYPEDSIGNATURES)
"
isincomplete(candle::Candle, tf::TimeFrame) = isincomplete(candle.timestamp, tf)
@doc "Checks if a candle is old enough to be complete.

$(TYPEDSIGNATURES)
"
iscomplete(v, tf) = !isincomplete(v, tf)
@doc "Checks if a candle is exactly the latest candle.

$(TYPEDSIGNATURES)
"
islast(d::DateTime, tf, ::Val{:raw}) = begin
    n = now()
    next = d + tf
    next <= n && next + tf > n
end
islast(d::DateTime, tf::TimeFrame) = islast(apply(tf, d), tf, Val(:raw))
islast(candle::Candle, tf) = islast(candle.timestamp, tf, Val(:raw))
islast(v, tf::AbstractString) = islast(v, timeframe(tf))
islast(v::AbstractString, tf) = islast(something(tryparse(DateTime, v), DateTime(0)), tf)
islast(v::S, tf::S) where {S<:AbstractString} = islast(v, timeframe(tf))
_equalapply(date1, tf, date2) = apply(tf, date1) - period(tf) == date2
@doc """Checks if the last row of a smaller DataFrame is also the last row of a larger DataFrame.

$(TYPEDSIGNATURES)

"""
function islast(larger::DataFrame, smaller::DataFrame)
    let tf = timeframe!(larger), date = lastdate(smaller)
        _equalapply(date, tf, lastdate(larger))
    end
end
@doc "`a` is left adjacent to `b` if in order `..ab..`

$(TYPEDSIGNATURES)
"
isleftadj(a, b, tf::TimeFrame) = a + tf == b
@doc "`a` is right adjacent to `b` if in order `..ba..`

$(TYPEDSIGNATURES)
"
isrightadj(a, b, tf::TimeFrame) = isleftadj(b, a, tf)
@doc "`a` is adjacent to `b` if either [`isleftadj`](@ref) or [`isrightadj`](@ref)."
isadjacent(a, b, tf::TimeFrame) = isleftadj(a, b, tf) || isrightadj(a, b, tf)

export cleanup_ohlcv_data,
    isincomplete, iscomplete, islast, isleftadj, isrightadj, isadjacent
