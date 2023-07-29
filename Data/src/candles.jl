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

function to_ohlcv(data::V, timeframe::T) where {V<:AbstractVector{Candle},T<:TimeFrame}
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
function candleat(df::D, date::DateTime; return_idx=false) where {D<:AbstractDataFrame}
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

function openat(df::D, date::DateTime; return_idx=false) where {D<:AbstractDataFrame}
    @candleat open
end
function highat(df::D, date::DateTime; return_idx=false) where {D<:AbstractDataFrame}
    @candleat high
end
lowat(df::D, date::DateTime; return_idx=false) where {D<:AbstractDataFrame} = @candleat low
function closeat(df::D, date::DateTime; return_idx=false) where {D<:AbstractDataFrame}
    @candleat close
end
function volumeat(df::D, date::DateTime; return_idx=false) where {D<:AbstractDataFrame}
    @candleat volume
end

@doc "Same as `candleat` but also fetches the previous candle, returning a `Tuple{Candle, Candle}`."
function candlepair(df::D, date::DateTime) where {D<:AbstractDataFrame}
    idx = searchsortedlast(df.timestamp, date)
    (; prev=_candleidx(df, idx - 1, date), this=_candleidx(df, idx, date))
end

@doc "Get the last candle from a ohlcv dataframe as a `Candle`."
function candlelast(df::D) where {D<:AbstractDataFrame}
    idx = lastindex(df.timestamp)
    _candleidx(df, idx, df.timestamp[idx])
end

macro candlelast(col)
    df = esc(:df)
    quote
        idx = lastindex($df.timestamp)
        $df.$col[idx]
    end
end

openlast(df::D) where {D<:AbstractDataFrame} = @candlelast open
highlast(df::D) where {D<:AbstractDataFrame} = @candlelast high
lowlast(df::D) where {D<:AbstractDataFrame} = @candlelast low
closelast(df::D) where {D<:AbstractDataFrame} = @candlelast close
volumelast(df::D) where {D<:AbstractDataFrame} = @candlelast volume

function candleavl(df::D, tf::TimeFrame, date) where {D<:AbstractDataFrame}
    candleat(df, available(tf, date))
end

macro candleavl(col)
    df = esc(:df)
    tf = esc(:tf)
    date = esc(:date)
    quote
        idx = searchsortedlast($df.timestamp, available($tf, $date))
        $df.$col[idx]
    end
end
openavl(df::D, tf::TimeFrame, date) where {D<:AbstractDataFrame} = @candleavl open
highavl(df::D, tf::TimeFrame, date) where {D<:AbstractDataFrame} = @candleavl high
lowavl(df::D, tf::TimeFrame, date) where {D<:AbstractDataFrame} = @candleavl low
closeavl(df::D, tf::TimeFrame, date) where {D<:AbstractDataFrame} = @candleavl close
volumeavl(df::D, tf::TimeFrame, date) where {D<:AbstractDataFrame} = @candleavl volume

export Candle, candleat, candlelast, candleavl
export openat, highat, lowat, closeat, volumeat
export openlast, highlast, lowlast, closelast, volumelast
export openavl, highavl, lowavl, closeavl, volumeavl
