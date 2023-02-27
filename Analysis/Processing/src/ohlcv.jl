using DataFramesMeta
using TimeTicks: Period, now, timeframe, apply
using DataFrames: clear_pt_conf!
using Base: _cleanup_locked
using TimeTicks
using Data: Candle, to_ohlcv, empty_ohlcv

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
@doc "`a` is left adjacent to `b` if in order `..ab..`"
isleftadj(a, b, tf::TimeFrame) = a + tf == b
@doc "`a` is right adjacent to `b` if in order `..ba..`"
isrightadj(a, b, tf::TimeFrame) = isleftadj(b, a, tf)
isadjacent(a, b, tf::TimeFrame) = isleftadj(a, b, tf) || isrightadj(a, b, tf)

export cleanup_ohlcv_data, isincomplete, iscomplete, islast, isleftadj, isrightadj, isadjacent
