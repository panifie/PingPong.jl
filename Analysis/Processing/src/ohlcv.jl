using DataFramesMeta
using Dates: Period, now, UTC
using TimeTicks
using Misc: Candle
using Data: to_ohlcv

@doc """Assuming timestamps are sorted, returns a new dataframe with a contiguous rows based on timeframe.
Rows are filled either by previous close, or NaN. """
fill_missing_rows(df, timeframe::AbstractString; strategy=:close) = begin
    @as_td
    _fill_missing_rows(df, prd; strategy, inplace=false)
end

fill_missing_rows!(df, prd::Period; strategy=:close) = begin
    _fill_missing_rows(df, prd; strategy, inplace=true)
end

fill_missing_rows!(df, timeframe::AbstractString; strategy=:close) = begin
    @as_td
    _fill_missing_rows(df, prd; strategy, inplace=true)
end

function _fill_missing_rows(df, prd::Period; strategy, inplace)
    size(df, 1) === 0 && return empty_ohlcv()
    let ordered_rows = []
        # fill the row by previous close or with NaNs
        can =
            strategy === :close ? (x) -> [x, x, x, x, 0] : (_) -> [NaN, NaN, NaN, NaN, NaN]
        @with df begin
            ts_cur, ts_end = first(:timestamp) + prd, last(:timestamp)
            ts_idx = 2
            # NOTE: we assume that ALL timestamps are multiples of the timedelta!
            while ts_cur < ts_end
                if ts_cur !== :timestamp[ts_idx]
                    close = :close[ts_idx-1]
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
@doc """Similar to the freqtrade homonymous function.
- `fill_missing`: `:close` fills non present candles with previous close and 0 volume, else with `NaN`.
"""
function cleanup_ohlcv_data(data, timeframe; col=1, fill_missing=:close)
    @debug "Cleaning dataframe of size: $(size(data, 1))."
    size(data, 1) === 0 && return empty_ohlcv()
    df = data isa DataFrame ? data : to_ohlcv(data)

    @as_td

    # For when for example 1d candles start at hours other than 00
    ts_float = timefloat.(df.timestamp)
    ts_offset = ts_float .% td
    if all(ts_offset .== ts_offset[begin])
        @debug "Offsetting timestamps for $(ts_offset[begin])."
        df.timestamp .= (ts_float .- ts_offset[begin]) .|> dt
    end

    # remove rows with bad timestamps
    # delete!(df, timefloat.(df.timestamp) .% td .!== 0.)
    # @debug "DataFrame without bad timestamp size: $(size(df, 1))"

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

    if is_incomplete_candle(df[end, :], td)
        last_candle = copy(df[end, :])
        delete!(df, lastindex(df, 1))
        @debug "Dropping last candle ($(last_candle[:timestamp] |> string)) because it is incomplete."
    end
    if fill_missing !== false
        fill_missing_rows!(df, prd; strategy=fill_missing)
    end
    df
end

@doc "Checks if a candle timestamp is too new."
@inline function is_incomplete_candle(ts::F, td::F) where {F<:AbstractFloat}
    nw = timefloat(now(UTC))
    ts + td > nw
end

@inline function is_incomplete_candle(x::String, td::AbstractFloat)
    ts = timefloat(x)
    is_incomplete_candle(ts, td)
end

@inline function is_incomplete_candle(candle, td::AbstractFloat)
    ts = timefloat(candle.timestamp)
    is_incomplete_candle(ts, td)
end

@inline function is_incomplete_candle(x, timeframe="1m")
    @as_td
    is_incomplete_candle(x, td)
end

@doc "Checks if a timestamp belongs to the newest possible candle of given timeframe."
function is_last_complete_candle(x, timeframe)
    @as_td
    ts = timefloat(x)
    is_incomplete_candle(ts + td, td)
end
