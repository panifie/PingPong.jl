using Dates:
    DateTime,
    AbstractDateTime,
    Period,
    now,
    datetime2unix,
    unix2datetime,
    Millisecond,
    Second,
    Minute,
    Hour,
    Day,
    Week,
    Month,
    Year
using DataFrames: AbstractDataFrame, DataFrame, groupby, combine
using Zarr: ZArray
using TimeFrames: TimeFrame
using Base.Meta: parse
import Base.convert
import Base.isless
using PythonCall: Py

const DateType = Union{AbstractString,AbstractDateTime,AbstractFloat,Integer}
const StrOrVec = Union{AbstractString,AbstractVector}

const OHLCV_COLUMNS = [:timestamp, :open, :high, :low, :close, :volume]
const OHLCV_COLUMNS_TS = setdiff(OHLCV_COLUMNS, [:timestamp])
const OHLCV_COLUMNS_NOV = setdiff(OHLCV_COLUMNS, [:timestamp, :volume])

const default_data_path =
    get(ENV, "XDG_CACHE_DIR", "$(joinpath(ENV["HOME"], ".cache", "Backtest.jl", "data"))")

macro as(sym, val)
    s = esc(sym)
    v = esc(val)
    quote
        $s = $v
        true
    end
end

# stdlib doesn't have this function
@doc "A week should be less than a month."
isless(w::Week, m::Month) = w.value * 7 < m.value * 30

@doc "Parses a string into a `TimeFrame` according to (ccxt) timeframes nomenclature."
function convert(::Type{TimeFrame}, s::AbstractString)::TimeFrame
    m = match(r"([0-9]+)([a-zA-Z])", s)
    n = m[1]
    t = lowercase(m[2])
    # convert m for minutes to T, since ccxt uses lowercase "m" for minutes
    if t == "m"
        t = "T"
    elseif t == "y"
        t = "d"
        n = parse(n) * 365
    end
    TimeFrame("$n$t")
end

@inline tfperiod(s::AbstractString) = convert(TimeFrame, s).period
function convert(::Type{String}, tf::T) where {T<:TimeFrame}
    tostring(unit::String) = "$(tf.period.value)$(unit)"
    prd = tf.period
    if prd isa Second
        "s"
    elseif prd isa Minute
        "m"
    elseif prd isa Hour
        "h"
    elseif prd isa Day
        "d"
    elseif prd isa Week
        "w"
    elseif prd isa Month
        "M"
    else
        "y"
    end |> tostring
end

# ccxt always uses milliseconds in timestamps
tfnum(prd::Period) = convert(Millisecond, prd) |> x -> convert(Float64, x.value)

@doc "Binds period `prd` and time delta `td` variables from a string `timeframe` variable."
macro as_td()
    tfs = esc(:timeframe)
    tf = esc(:tf)
    td = esc(:td)
    prd = esc(:prd)
    quote
        $tf = convert(TimeFrame, $tfs)
        $prd = tf.period
        $td = tfnum($prd)
    end
end

struct PairData
    name::String
    tf::String # string
    data::Union{Nothing,AbstractDataFrame} # in-memory data
    z::Union{Nothing,ZArray} # reference zarray
end

PairData(; name, tf, data, z) = PairData(name, tf, data, z)
convert(
    ::Type{T},
    d::AbstractDict{String,PairData},
) where {T<:AbstractDict{String,N}} where {N<:AbstractDataFrame} =
    Dict(p.name => p.data for p in values(d))

OptionsDict = Dict{String,Dict{String,Any}}
mutable struct Exchange
    py::Py
    isset::Bool
    timeframes::Set{String}
    name::String
    sym::Symbol
    markets::OptionsDict
    Exchange() = new(pynew())
    Exchange(x::Py) = new(x, false, Set(), "", Symbol(), Dict())
end

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

    if from !== ""
        from =
            typeof(from) <: Int ? from :
            something(tryparse(Int, from), tryparse(DateTime, from), from)
        typeof(from) <: Int && begin
            from = from === 0 ? DateTime(0) : now() - (abs(from) * prd)
        end
    end
    if to !== ""
        to =
            typeof(to) <: Int ? to :
            something(tryparse(Int, to), tryparse(DateTime, to), to)
        typeof(to) <: Int && begin
            to = to === 0 ? now() : now() - (abs(to) * prd)
        end
    end
    from, to
end

@doc "An empty OHLCV dataframe."
function _empty_df()
    DataFrame(
        [DateTime[], [Float64[] for _ in OHLCV_COLUMNS_TS]...],
        OHLCV_COLUMNS;
        copycols = false,
    )
end

# needed to convert an ohlcv dataframe with DateTime timestamps to a Float Matrix
convert(::Type{T}, x::DateTime) where {T<:AbstractFloat} = timefloat(x)

dt(::Nothing) = :nothing
dt(d::DateTime) = d
dt(num::Real) = unix2datetime(num / 1e3)
dtfloat(d::DateTime)::Float64 = datetime2unix(d) * 1e3

timefloat(time::Float64) = time
timefloat(prd::Period) = prd.value * 1.0
timefloat(time::DateTime) = dtfloat(time)

function timefloat(time::String)
    time === "" && return dtfloat(dt(0))
    DateTime(time) |> dtfloat
end

timefloat(tf::Symbol) = tf |> string |> tfperiod |> tfnum

@doc "Given a dataframe, infer the timeframe by looking at the first two and the last two candles timestamp."
function infer_tf(df::AbstractDataFrame)
    td1 = df.timestamp[begin+1] - df.timestamp[begin]
    td2 = df.timestamp[end] - df.timestamp[end-1]
    @assert td1 === td2
    tfname = td_tf[td1.value]
    TimeFrame(td1), tfname
end

@doc "Binds a `mrkts` variable to a Dict{String, DataFrame} \
where the keys are the pairs names and the data is the OHLCV data of the pair."
macro as_dfdict(data, skipempty = true)
    data = esc(data)
    mrkts = esc(:mrkts)
    quote
        if valtype($data) <: PairData
            $mrkts = Dict(p.name => p.data for p in values($data) if size(p.data, 1) > 0)
        end
    end
end

include("exceptions.jl")

export ZarrInstance, Candle
