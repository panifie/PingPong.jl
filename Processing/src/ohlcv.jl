using TimeTicks
using TimeTicks: Period, now, timeframe, apply
using Data.DataFramesMeta
using Data.DataFrames: clear_pt_conf!
using Data: Candle, to_ohlcv, empty_ohlcv, DFUtils
using Base: _cleanup_locked
using .DFUtils: appendmax!

@doc """Assuming timestamps are sorted, returns a new dataframe with a contiguous rows based on timeframe.
Rows are filled either by previous close, or NaN. """
function fill_missing_candles(df, timeframe::AbstractString; strategy=:close)
    @as_td
    _fill_missing_candles(df, prd; strategy, inplace=false)
end

function fill_missing_candles!(df, prd::Period; strategy=:close)
    _fill_missing_candles(df, prd; strategy, inplace=true)
end

function fill_missing_candles!(df, timeframe::AbstractString; strategy=:close)
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

@doc "Appends empty candles to df up to `to` datetime (excluded).
`cap`: max capacity of `df`
"
trail!(df, tf::TimeFrame; to, from=df[end, :timestamp], cap=0) = begin
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

function _fill_missing_candles(df, prd::Period; strategy, inplace)
    size(df, 1) == 0 && return empty_ohlcv()
    ordered_rows = Candle[]
    # fill the row by previous close or with NaNs
    build_candle = ifelse(strategy == :close, novol_candle, nan_candle)
    @with df begin
        ts_cur, ts_end = first(:timestamp) + prd, last(:timestamp)
        ts_idx = 2
        # NOTE: we assume that ALL timestamps are multiples of the timedelta!
        while ts_cur < ts_end
            if ts_cur != :timestamp[ts_idx]
                close = :close[ts_idx-1]
                push!(ordered_rows, build_candle(ts_cur, close))
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

function _remove_incomplete_candle(in_df, tf)
    df = in_df isa SubDataFrame ? copy(in_df) : in_df
    if isincomplete(df[end, :timestamp], tf)
        last_candle = copy(df[end, :])
        deleteat!(df, lastindex(df, 1))
        @debug "Dropping last candle ($(last_candle[:timestamp] |> string)) because it is incomplete."
    end
    df
end
@doc """Similar to the freqtrade homonymous function.
- `fill_missing`: `:close` fills non present candles with previous close and 0 volume, else with `NaN`.
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
        renamecols=false
    )
    # check again after de-duplication
    df = _remove_incomplete_candle(df, tf)

    if fill_missing != false
        fill_missing_candles!(df, tf.period; strategy=fill_missing)
    end
    df
end
function cleanup_ohlcv_data(data, tf::AbstractString; kwargs...)
    cleanup_ohlcv_data(data, convert(TimeFrame, tf); kwargs...)
end

isincomplete(d::DateTime, tf::TimeFrame, ::Val{:raw}) = d + tf > now()
isincomplete(d::DateTime, tf::TimeFrame) = isincomplete(apply(tf, d), tf, Val(:raw))
@doc "Checks if a candle is too new."
isincomplete(candle::Candle, tf::TimeFrame) = isincomplete(candle.timestamp, tf)
@doc "Checks if a candle is old enough to be complete."
iscomplete(v, tf) = !isincomplete(v, tf)
@doc "Checks if a candle is exactly the latest candle."
islast(d::DateTime, tf, ::Val{:raw}) = begin
    n = now()
    next = d + tf
    next <= n && next + tf > n
end
islast(d::DateTime, tf::TimeFrame) = islast(apply(tf, d), tf, Val(:raw))
islast(candle::Candle, tf) = islast(candle.timestamp, tf, Val(:raw))
islast(v, tf::AbstractString) = islast(v, timeframe(tf))
islast(v::AbstractString, tf) = islast(something(tryparse(DateTime, v), DateTime(0)), tf)
@doc "`a` is left adjacent to `b` if in order `..ab..`"
isleftadj(a, b, tf::TimeFrame) = a + tf == b
@doc "`a` is right adjacent to `b` if in order `..ba..`"
isrightadj(a, b, tf::TimeFrame) = isleftadj(b, a, tf)
isadjacent(a, b, tf::TimeFrame) = isleftadj(a, b, tf) || isrightadj(a, b, tf)

export cleanup_ohlcv_data, isincomplete, iscomplete, islast, isleftadj, isrightadj, isadjacent
