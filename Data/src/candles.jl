@enum CandleField cdl_ts = 1 cdl_o = 2 cdl_h = 3 cdl_lo = 4 cdl_cl = 5 cdl_vol = 6
const CandleCol = (; timestamp=1, open=2, high=3, low=4, close=5, volume=6)

@kwdef struct Candle{T<:AbstractFloat}
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

function to_ohlcv(data::AbstractVector{Candle}, timeframe::TimeFrame)
    df = DataFrame(data; copycols=false)
    df.timestamp[:] = apply.(timeframe, df.timestamp)
    df
end

default(::Type{Candle}) = Candle(DateTime(0), 0, 0, 0, 0, 0)

Base.convert(::Type{Candle}, row::DataFrameRow) = Candle(row...)

function _candleidx(df, idx, date)
    Candle(date, df.open[idx], df.high[idx], df.low[idx], df.close[idx], df.volume[idx])
end

@doc "Get the candle at given date from a ohlcv dataframe as a `Candle`."
function candleat(df::AbstractDataFrame, date::DateTime; return_idx=false)
    idx = searchsortedlast(df.timestamp, date)
    cdl = _candleidx(df, idx, date)
    return_idx ? (cdl, idx) : cdl
end

macro candleat(col)
    df = esc(:df)
    date = esc(:date)
    return_idx = esc(:return_idx)
    quote
        idx = searchsortedlast($df.timestamp, $date)
        v = $df.$col[idx]
        $return_idx ? (v, idx) : v
    end
end

openat(df::AbstractDataFrame, date::DateTime; return_idx=false) = @candleat open
highat(df::AbstractDataFrame, date::DateTime; return_idx=false) = @candleat high
lowat(df::AbstractDataFrame, date::DateTime; return_idx=false) = @candleat low
closeat(df::AbstractDataFrame, date::DateTime; return_idx=false) = @candleat close
volumeat(df::AbstractDataFrame, date::DateTime; return_idx=false) = @candleat volume

@doc "Same as `candleat` but also fetches the previous candle, returning a `Tuple{Candle, Candle}`."
function candlepair(df::AbstractDataFrame, date::DateTime)
    idx = searchsortedlast(df.timestamp, date)
    (; prev=_candleidx(df, idx - 1, date), this=_candleidx(df, idx, date))
end

export Candle, candleat, openat, highat, lowat, closeat, volumeat
