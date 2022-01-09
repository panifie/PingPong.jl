using Dates: DateTime, AbstractDateTime, Period, Millisecond, now
using DataFrames: AbstractDataFrame, DataFrame
using Zarr: ZArray
using TimeFrames: TimeFrame
import Base.convert

const DateType = Union{AbstractString, AbstractDateTime, AbstractFloat, Integer}
const StrOrVec = Union{AbstractString, AbstractVector}

const OHLCV_COLUMNS = [:timestamp, :open, :high, :low, :close, :volume]
const OHLCV_COLUMNS_TS = setdiff(OHLCV_COLUMNS, [:timestamp])
const OHLCV_COLUMNS_NOV = setdiff(OHLCV_COLUMNS, [:timestamp, :volume])

macro as(sym, val)
    s = esc(sym)
    v = esc(val)
    quote
        $s = $v
        true
    end
end

function tfperiod(s::AbstractString)
    # convert m for minutes to T
    TimeFrame(replace(s, r"([0-9]+)m" => s"\1T")).period
end

function tfnum(prd::Period)
    convert(Millisecond, prd) |> x -> convert(Float64, x.value)
end

macro as_td()
    tf = esc(:timeframe)
    td = esc(:td)
    prd = esc(:prd)
    quote
        $prd = tfperiod($tf)
        $td = tfnum($prd)
    end
end

struct PairData
    name::String
    tf::String # string
    data::Union{Nothing, AbstractDataFrame} # in-memory data
    z::Union{Nothing, ZArray} # reference zarray
end

PairData(;name, tf, data, z) = PairData(name, tf, data, z)

struct Candle
    timestamp::DateTime
    open::AbstractFloat
    high::AbstractFloat
    low::AbstractFloat
    close::AbstractFloat
    volume::AbstractFloat
end


@doc "Converts integers to relative datetimes according to timeframe duration."
_from_to_dt(timeframe::AbstractString, from, to) = begin
    @as_td
    typeof(from) <: Int && begin
        from = from === 0 ? DateTime(0) : now() - (abs(from) * prd)
    end
    typeof(to) <: Int && begin
        to = to === 0 ? now() : now() - (abs(to) * prd)
    end
    from, to
end

@doc "An empty OHLCV dataframe."
function _empty_df()
    DataFrame([DateTime[], [Float64[] for _ in OHLCV_COLUMNS_TS]...], OHLCV_COLUMNS; copycols=false)
end

# needed to convert an ohlcv dataframe with DateTime timestamps to a Float Matrix
convert(::Type{T}, x::DateTime) where T <: AbstractFloat = timefloat(x)

include("exceptions.jl")

export ZarrInstance
