using Reexport
@reexport using Dates
using TimeFrames: TimeFrames, TimeFrame, apply, TimePeriodFrame
using Lang: @lget!, Lang
using Serialization
using Base: AbstractCmd
import Base: convert, isless, ==
using Base.Meta: parse

include("consts.jl")

@doc "Exported `Dates.now(UTC)` to avoid inadvertently calling now() which defaults to system timezone."
now() = Dates.now(UTC)

@doc "Parses a string into a `TimeFrame` according to (ccxt) timeframes nomenclature.
Units bigger than days are converted to the equivalent number of days days."
function Base.parse(::Type{TimeFrame}, s::AbstractString)::TimeFrame
    mul = 0
    m = match(r"([0-9]+)([a-zA-Z]+)", s)
    n = m[1]
    t = m[2]
    # convert m for minutes to T, since ccxt uses lowercase "m" for minutes
    if t == "ms"
        return TimeFrame(Millisecond(parse(n)))
    elseif t == "m"
        t = "T"
    elseif t == "w" || t == "W" # Weeks
        mul = 7
    elseif t == "M" # Months
        mul = 30
    elseif t == "y" || t == "Y"
        mul = 365
    end
    if mul > 0
        t = "d"
        n = parse(n) * mul
    end
    TimeFrame("$n$t")
end
const tf_parse_map = Dict{String,TimeFrame}()
convert(t::Type{TimeFrame}, s::AbstractString) = @lget! tf_parse_map s Base.parse(t, s)
period(t::TimeFrame) = t.period

@doc "Comparison between timeframes"
isless(t1::TimeFrame, t2::TimeFrame) = isless(t1.period, t2.period)
==(t1::TimeFrame, t2::TimeFrame) = t1.period == t2.period
# stdlib doesn't have this function
@doc "A week should be less than a month."
isless(w::Week, m::Month) = w.value * 7 < m.value * 30
==(w::Week, m::Month) = w.value * 7 == m.value * 30

@doc "Convert to timeframes, strings prefixed with 'tf' diffrent from the one in TimeFrames."
macro tf_str(s)
    quote
        $(convert(TimeFrame, s))
    end
end

@inline todatetime(s::AbstractString) = DateTime(s, ISODateTimeFormat)

@doc "Convert to datetime, strings prefixed with 'dt'."
macro dt_str(s)
    quote
        $(todatetime(s))
    end
end

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
            (tf, timefloat(tf))
        end
        $prd = $tf.period
    end
end

@doc "Converts integers to relative datetimes according to given period."
function from_to_dt(prd::Period, from, to)
    doparse(v) = v
    function doparse(v::AbstractString)
        @something tryparse(Int, v) tryparse(DateTime, v) v
    end
    reldate(v, _) = v
    reldate(v::Int, defv) =
        if v == 0
            defv
        elseif prd.value == 0
            v
        else
            now() - (abs(v) * prd)
        end
    from != "" && begin
        from = doparse(from) |> x -> reldate(x, DateTime(0))
    end
    to != "" && begin
        to = doparse(to) |> x -> reldate(x, now())
    end
    from, to
end
from_to_dt(from, to) = from_to_dt(Second(0), from, to)
function from_to_dt(timeframe, from, to)
    from_to_dt(convert(TimeFrame, timeframe).period, from, to)
end
from_to_dt(tf::TimeFrame, args...) = from_to_dt(tf.period, args...)

Base.Broadcast.broadcastable(tf::TimeFrame) = Ref(tf)
# dateformat with millis at the end "sss"
function convert(::Type{DateTime}, s::AbstractString)
    DateTime(s, dateformat"yyyy-mm-dd\THH:MM:SS.sss")
end
# needed to convert an ohlcv dataframe with DateTime timestamps to a Float Matrix
convert(::Type{T}, x::DateTime) where {T<:AbstractFloat} = timefloat(x)

function Base.nameof(tf::TimeFrame)
    tostring(unit::String) = "$(tf.period.value)$(unit)"
    prd = tf.period
    tostring(
        if prd isa Nanosecond
            "ns"
        elseif prd isa Millisecond
            "ms"
        elseif prd isa Second
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
        end,
    )
end

const tf_name_map = Dict{Period,String}() # FIXME: this should be benchmarked to check if caching is worth it
convert(::Type{<:AbstractString}, tf::TimeFrame) = @lget! tf_name_map tf.period Base.nameof(tf)
Base.string(tf::TimeFrame) = convert(String, tf)
ms(tf::TimeFrame) = Millisecond(period(tf))
ms(prd::Period) = Millisecond(prd)
ms(v) = Millisecond(v)
timeframe(s::AbstractString) = convert(TimeFrame, s)
timeframe(n::AbstractFloat) = TimeFrame(Millisecond(n))
timeframe!(args...; kwargs...) = error("Not implemented")

dt(::Nothing) = :nothing
dt(d::DateTime) = d
dt(num::R) where {R<:Real} = unix2datetime(num / 1e3)
dtfloat(d::DateTime)::Float64 = datetime2unix(d) * 1e3
dtstamp(d::I) where {I<:Integer} = d
dtstamp(d::F) where {F<:AbstractFloat} = dt(d) |> dtstamp
dtstamp(d::DateTime)::Int64 = datetime2unix(d) * 1_000
dtstamp(d::DateTime, ::Val{:round})::Int64 = round(Int, timefloat(d))

timefloat(time::Float64) = time
timefloat(time::Int64) = timefloat(Float64(time))
@doc "ccxt always uses milliseconds in timestamps."
timefloat(prd::P) where {P<:Period} = convert(Float64, convert(Millisecond, prd).value)
timefloat(tf::T) where {T<:TimeFrame} = timefloat(tf.period)
timefloat(time::DateTime) = dtfloat(time)
timefloat(time::Vector{UInt8}) = begin
    buf = Base.IOBuffer(time)
    try
        timefloat(deserialize(buf))
    finally
        close(buf)
    end
end

function timefloat(time::String)
    time === "" && return dtfloat(dt(0))
    timefloat(DateTime(time))
end

timefloat(tf::Symbol) = timefloat(convert(TimeFrame, string(tf)))

@doc "Converts date into an Integer unix timestamp (seconds)."
timestamp(s::AbstractString) = timestamp(DateTime(s))
@doc "Convertes a datetime into a timestamp."
timestamp(d::DateTime) = round(Int64, datetime2unix(d))
timestamp(d::DateTime, ::Val{:trunc}) = Int(trunc(datetime2unix(d)))

@doc "Given a container, infer the timeframe by looking at the first two \
 and the last two elements timestamp."
macro infertf(data, field=:timestamp)
    quote
        begin
            arr = getproperty($(esc(data)), $(QuoteNode(field)))
            td1 = arr[begin + 1] - arr[begin]
            td2 = arr[end] - arr[end - 1]
            @assert td1 === td2 """mismatch in dataframe dates found!
            1: $(arr[begin])
            2: $(arr[begin+1])
            -2: $(arr[end-1])
            -1: $(arr[end])"""
            $TimeFrame(td1)
        end
    end
end

function TimeFrames.apply(period::N, time::N) where {N<:Number}
    inv_prec = 1.0 / period
    round(time * inv_prec) / inv_prec
end

const tf_conv_map = Dict{Period,TimeFrame}()
function convert(::Type{TimeFrames.Minute}, v::TimePeriodFrame{Millisecond})
    @lget! tf_conv_map v.period begin
        TimeFrame(Minute(v.period.value ÷ 60 ÷ 1000))
    end
end
convert(::Type{TimeFrames.Minute}, v::TimeFrames.Day) = tf"1440m"
convert(::Type{TimeFrames.Minute}, v::TimeFrames.Hour) = tf"60m"
convert(::Type{TimeFrames.Second}, v::TimeFrames.Hour) = tf"3600s"

@doc "Returns the correct timeframe normalized timestamp that the strategy should access from the input date."
function available(frame::T, date::DateTime)::DateTime where {T<:TimeFrame}
    apply(frame, date) - frame.period
end

@doc "Converts period in the most readable format up to days."
function compact(s::Period)
    millis = Millisecond(s)
    ms = millis.value
    if ms < 1000
        millis
    elseif ms < 120_000
        round(s, Second)
    elseif ms < 3_600_000
        round(s, Minute)
    elseif ms < 86_400_000
        round(s, Hour)
    else
        round(s, Day)
    end
end

function Base.count(tf1::T1, tf2::T2) where {T1,T2<:TimeFrame}
    trunc(Int, timefloat(tf2) / timefloat(tf1))
end

# HACK
Base.round(p::Dates.CompoundPeriod, t, args...) =
    let ans = zero(t)
        for this in p.periods
            ans += round(this, t, args...)
        end
        ans
    end

export @as_td, @infertf
export @tf_str, @dt_str
export TimeFrame, timeframe, timeframe!, period, apply
export dt, ms, timefloat, dtfloat
export now, available, from_to_dt
export compact

include("daterange.jl")         #
