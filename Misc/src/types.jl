using Dates
using DataFrames: AbstractDataFrame, DataFrame, groupby, combine
using Zarr: ZArray
using TimeFrames: TimeFrame, apply
using Base.Meta: parse
import Base: convert, isless, ==

const DateType = Union{AbstractString,AbstractDateTime,AbstractFloat,Integer}
const StrOrVec = Union{AbstractString,AbstractVector}

const OHLCV_COLUMNS = [:timestamp, :open, :high, :low, :close, :volume]
const OHLCV_COLUMNS_TS = setdiff(OHLCV_COLUMNS, [:timestamp])
const OHLCV_COLUMNS_NOV = setdiff(OHLCV_COLUMNS, [:timestamp, :volume])

const DATA_PATH =
    get(ENV, "XDG_CACHE_DIR", "$(joinpath(ENV["HOME"], ".cache", "JuBot.jl", "data"))")

const Iterable = Union{AbstractVector{T},AbstractSet{T}} where {T}

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
==(w::Week, m::Month) = w.value * 7 == m.value * 30

@doc "Comparison between timeframes"
isless(t1::TimeFrame, t2::TimeFrame) = isless(t1.period, t2.period)
==(t1::TimeFrame, t2::TimeFrame) = t1.period == t2.period

@doc "Parses a string into a `TimeFrame` according to (ccxt) timeframes nomenclature.
Units bigger than days are converted to the equivalent number of days days."
function convert(::Type{TimeFrame}, s::AbstractString)::TimeFrame
    mul = 0
    m = match(r"([0-9]+)([a-zA-Z])", s)
    n = m[1]
    t = m[2]
    # convert m for minutes to T, since ccxt uses lowercase "m" for minutes
    if t == "m"
        t = "T"
    elseif t == "w" # Weeks
        mul = 7
    elseif t == "M" # Months
        mul = 30
    elseif t == "y"
        mul = 365
    end
    if mul > 0
        t = "d"
        n = parse(n) * mul
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

const tf_map = Dict{String,Tuple{TimeFrame,Float64}}() # FIXME: this should be benchmarked to check if caching is worth it
@doc "Binds period `prd` and time delta `td` variables from a string `timeframe` variable."
macro as_td()
    timeframe = esc(:timeframe)
    tf = esc(:tf)
    td = esc(:td)
    prd = esc(:prd)
    quote
        ($tf, $td) = @lget! $tf_map $timeframe begin
            tf = convert(TimeFrame, $timeframe)
            (tf, tfnum(tf.period))
        end
        $prd = $tf.period
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
        from = if typeof(from) <: Int
            from
        else
            something(tryparse(Int, from), tryparse(DateTime, from), from)
        end
        typeof(from) <: Int && begin
            from = from === 0 ? DateTime(0) : now() - (abs(from) * prd)
        end
    end
    if to !== ""
        to = if typeof(to) <: Int
            to
        else
            something(tryparse(Int, to), tryparse(DateTime, to), to)
        end
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
        copycols=false,
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
macro as_dfdict(data, skipempty=true)
    data = esc(data)
    mrkts = esc(:mrkts)
    quote
        if valtype($data) <: PairData
            $mrkts = Dict(p.name => p.data for p in values($data) if size(p.data, 1) > 0)
        end
    end
end

include("exceptions.jl")

@doc "Convert to timeframes, strings prefixed with 'tf' diffrent from the one in TimeFrames."
macro tf_str(s)
    convert(TimeFrame, s)
end

@doc "Convert to datetime, strings prefixed with 'd'."
macro dt_str(s)
    DateTime(s, ISODateFormat)
end

Base.Broadcast.broadcastable(tf::TimeFrame) = Ref(tf)

export Candle, Iterable, @tf_str, apply, @dt_str
