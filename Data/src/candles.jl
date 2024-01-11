@enum CandleField cdl_ts = 1 cdl_o = 2 cdl_h = 3 cdl_lo = 4 cdl_cl = 5 cdl_vol = 6
const CandleCol = (; timestamp=1, open=2, high=3, low=4, close=5, volume=6)

@doc """A struct representing a candlestick in financial trading.

$(FIELDS)

Candle{T} is a parametric struct that represents a candlestick with generic type T, which must be a subtype of AbstractFloat.
"""
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

@doc """Convert data to OHLCV format.

$(TYPEDSIGNATURES)

This function converts the input data to the OHLCV (Open, High, Low, Close, Volume) format, using the specified timeframe. It returns the converted data as a DataFrame.
"""
function to_ohlcv(data::V, timeframe::T) where {V<:AbstractVector{Candle},T<:TimeFrame}
    df = DataFrame(data; copycols=false)
    df.timestamp[:] = apply.(timeframe, df.timestamp)
    df
end

default_value(::Type{Candle}) = Candle(DateTime(0), 0, 0, 0, 0, 0)

Base.convert(::Type{Candle}, row::DataFrameRow) = Candle(row...)

function _candleidx(df, idx, date)
    Candle(date, df.open[idx], df.high[idx], df.low[idx], df.close[idx], df.volume[idx])
end

@doc """Get the candle at given date from a ohlcv dataframe as a `Candle`.

$(TYPEDSIGNATURES)
"""
function candleat(df::D, date::DateTime; return_idx=false) where {D<:AbstractDataFrame}
    idx = searchsortedlast(df.timestamp, date)
    cdl = _candleidx(df, idx, date)
    return_idx ? (cdl, idx) : cdl
end

@doc """Get the candle value at a specific date from an OHLCV DataFrame.

$TYPEDSIGNATURES

This function returns the requested value at the specified date from the input OHLCV DataFrame. The optional parameter `return_idx` determines whether to also return the index of the opening price.
"""
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

@doc "See [`@candleat`](@ref)."
function openat(df::D, date::DateTime; return_idx=false) where {D<:AbstractDataFrame}
    @candleat open
end
@doc "See [`@candleat`](@ref)."
function highat(df::D, date::DateTime; return_idx=false) where {D<:AbstractDataFrame}
    @candleat high
end
@doc "See [`@candleat`](@ref)."
lowat(df::D, date::DateTime; return_idx=false) where {D<:AbstractDataFrame} = @candleat low
@doc "See [`@candleat`](@ref)."
function closeat(df::D, date::DateTime; return_idx=false) where {D<:AbstractDataFrame}
    @candleat close
end
@doc "See [`@candleat`](@ref)."
function volumeat(df::D, date::DateTime; return_idx=false) where {D<:AbstractDataFrame}
    @candleat volume
end

@doc "Same as `candleat` but also fetches the previous candle, returning a `Tuple{Candle, Candle}`."
function candlepair(df::D, date::DateTime) where {D<:AbstractDataFrame}
    idx = searchsortedlast(df.timestamp, date)
    (; prev=_candleidx(df, idx - 1, date), this=_candleidx(df, idx, date))
end

@doc """Get the last candle from a ohlcv dataframe as a `Candle`.

$(TYPEDSIGNATURES)
"""
function candlelast(df::D) where {D<:AbstractDataFrame}
    idx = lastindex(df.timestamp)
    _candleidx(df, idx, df.timestamp[idx])
end

@doc """Get the last candle value from an OHLCV DataFrame (`df`).

$(TYPEDSIGNATURES)
"""
macro candlelast(col)
    df = esc(:df)
    quote
        idx = lastindex($df.timestamp)
        $df.$col[idx]
    end
end

@doc "See [`@candlelast`](@ref)"
openlast(df::D) where {D<:AbstractDataFrame} = @candlelast open
@doc "See [`@candlelast`](@ref)"
highlast(df::D) where {D<:AbstractDataFrame} = @candlelast high
@doc "See [`@candlelast`](@ref)"
lowlast(df::D) where {D<:AbstractDataFrame} = @candlelast low
@doc "See [`@candlelast`](@ref)"
closelast(df::D) where {D<:AbstractDataFrame} = @candlelast close
@doc "See [`@candlelast`](@ref)"
volumelast(df::D) where {D<:AbstractDataFrame} = @candlelast volume

@doc """Fetch the candle *expected to be available* at a specific date and time frame from an OHLCV DataFrame.

$(TYPEDSIGNATURES)

The available candle is usually the candle that is date-wise left adjacent to the requested date.
"""
function candleavl(df::D, tf::TimeFrame, date) where {D<:AbstractDataFrame}
    candleat(df, available(tf, date))
end

@doc """Fetch the candle value *expected to be available* at a specific date and time frame from an OHLCV DataFrame.

$(TYPEDSIGNATURES)

The available candle is usually the candle that is date-wise left adjacent to the requested date.
"""
macro candleavl(col)
    df = esc(:df)
    tf = esc(:tf)
    date = esc(:date)
    quote
        idx = searchsortedlast($df.timestamp, available($tf, $date))
        $df.$col[idx]
    end
end

@doc "See [`@candleavl`](@ref)"
openavl(df::D, tf::TimeFrame, date) where {D<:AbstractDataFrame} = @candleavl open
@doc "See [`@candleavl`](@ref)"
highavl(df::D, tf::TimeFrame, date) where {D<:AbstractDataFrame} = @candleavl high
@doc "See [`@candleavl`](@ref)"
lowavl(df::D, tf::TimeFrame, date) where {D<:AbstractDataFrame} = @candleavl low
@doc "See [`@candleavl`](@ref)"
closeavl(df::D, tf::TimeFrame, date) where {D<:AbstractDataFrame} = @candleavl close
@doc "See [`@candleavl`](@ref)"
volumeavl(df::D, tf::TimeFrame, date) where {D<:AbstractDataFrame} = @candleavl volume

export Candle, candleat, candlelast, candleavl
export openat, highat, lowat, closeat, volumeat
export openlast, highlast, lowlast, closelast, volumelast
export openavl, highavl, lowavl, closeavl, volumeavl
