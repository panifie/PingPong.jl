using Reexport
@reexport using Dates
using TimeFrames: TimeFrames, TimeFrame, apply, TimePeriodFrame
using Lang: @lget!, Lang
using Lang.DocStringExtensions
using Serialization
using Base: AbstractCmd
import Base: convert, isless, ==
using Base.Meta: parse

include("consts.jl")

@doc "Exported `Dates.now(UTC)` to avoid inadvertently calling now() which defaults to system timezone."
now() = Dates.now(UTC)

_parse_timeframe(s) = begin
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

@doc "Parses a string into a `TimeFrame` according to (ccxt) timeframes nomenclature.
Units bigger than days are converted to the equivalent number of days days."
function Base.parse(::Type{TimeFrame}, s::AbstractString)::TimeFrame
    _parse_timeframe(s)
end

# const tf_parse_map = Dict{String,TimeFrame}()
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

@doc """Return a string representation of the unit of time for the given TimeFrame tf.

$(TYPEDSIGNATURES)

The unit of time can be one of the following:

"ns" for nanoseconds
"ms" for milliseconds
"s" for seconds
"m" for minutes
...

Example:
```julia
tf = TimeFrame(Millisecond(500))
name = nameof(tf)  # returns "ms"
```
"""
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

convert(::Type{<:AbstractString}, tf::TimeFrame) = @lget! tf_name_map tf.period Base.nameof(tf)
Base.string(tf::TimeFrame) = convert(String, tf)
ms(tf::TimeFrame) = Millisecond(period(tf))
ms(prd::Period) = Millisecond(prd)
ms(prd::Dates.CompoundPeriod) = convert(Millisecond, prd)
ms(v) = Millisecond(v)
timeframe(s::AbstractString) = convert(TimeFrame, s)
timeframe(n::AbstractFloat) = TimeFrame(Millisecond(n))
timeframe!(args...; kwargs...) = error("Not implemented")

dt(::Nothing) = :nothing
dt(d::DateTime) = d
@doc """Convert a numeric value num representing the number of milliseconds since the Unix epoch to a DateTime object.

$(TYPEDSIGNATURES)

num should be a real number.
Example:
```julia
num = 1640995200000
d = dt(num)  # returns a DateTime object representing the date and time corresponding to the number of milliseconds
```
"""
dt(num::R) where {R<:Real} = unix2datetime(num / 1e3)
@doc """Convert a DateTime object d to a floating-point number representing the number of milliseconds since the Unix epoch.

$(TYPEDSIGNATURES)

Example:

```julia
d = DateTime(2022, 1, 1, 0, 0, 0)
tf = dtfloat(d)  # returns the number of milliseconds since the Unix epoch as a floating-point number
```
"""
dtfloat(d::DateTime)::Float64 = datetime2unix(d) * 1e3
dtstamp(d::I) where {I<:Integer} = d
dtstamp(d::F) where {F<:AbstractFloat} = dt(d) |> dtstamp
@doc """Generate a timestamp string in the format "YYYY-MM-DD HH:MM:SS" from a DateTime object d.

$(TYPEDSIGNATURES)

Example:

```julia
d = DateTime(2022, 1, 1, 0, 0, 0)
timestamp = dtstamp(d)  # returns "2022-01-01 00:00:00"
```
"""
dtstamp(d::DateTime)::Int64 = datetime2unix(d) * 1_000
dtstamp(d::DateTime, ::Val{:round})::Int64 = round(Int, timefloat(d))

@doc "Returns `time` (which should represent a date) as a float"
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

@doc """Given a container data, infer the timeframe by looking at the first two and the last two elements of the timestamp field.

$(TYPEDSIGNATURES)

This macro assumes that the timestamp field is available in the data container.

Example:

```julia
data = [1,2,3,4,5]
@infertf(data)  # infers the timeframe based on the timestamps in the data
```
"""
macro infertf(data, field=:timestamp)
    quote
        begin
            arr = getproperty($(esc(data)), $(QuoteNode(field)))
            td1 = arr[begin+1] - arr[begin]
            td2 = arr[end] - arr[end-1]
            @assert td1 === td2 """mismatch in dataframe dates found!
            1: $(arr[begin])
            2: $(arr[begin+1])
            -2: $(arr[end-1])
            -1: $(arr[end])"""
            $TimeFrame(td1)
        end
    end
end

@doc """Apply the TimeFrames object period to the time value and return the result.

$(TYPEDSIGNATURES)

The period should be a TimeFrames object and time should be a value of the same type as the TimeFrames object.

Example:

```julia
period = TimeFrame(Minute(1))
time = 30
result = TimeFrames.apply(period, time)  # returns the result of applying the period to the time value
```
"""
function TimeFrames.apply(period::N, time::N) where {N<:Number}
    inv_prec = 1.0 / period
    round(time * inv_prec) / inv_prec
end

function convert(::Type{TimeFrames.Minute}, v::TimePeriodFrame{Millisecond})
    @lget! tf_conv_map v.period begin
        TimeFrame(Minute(v.period.value ÷ 60 ÷ 1000))
    end
end
convert(::Type{TimeFrames.Minute}, v::TimeFrames.Day) = tf"1440m"
convert(::Type{TimeFrames.Minute}, v::TimeFrames.Hour) = tf"60m"
convert(::Type{TimeFrames.Second}, v::TimeFrames.Hour) = tf"3600s"

@doc """Returns the correct timestamp that the strategy should access from the input date for a given TimeFrame object frame.

$(TYPEDSIGNATURES)

frame should be a subtype of TimeFrame and date should be a DateTime object.

Example:

```julia
frame = TimeFrame(Minute(1))
date = DateTime(2022, 1, 1, 0, 2, 30)
timestamp = available(frame, date)  # returns the timestamp representing the start of the minute containing the input date
```
"""
function available(frame::T, date::DateTime)::DateTime where {T<:TimeFrame}
    apply(frame, date) - period(frame)
end

@doc """Compact a Period object s to a smaller unit of time if possible.

$(TYPEDSIGNATURES)

The function checks the value of s in milliseconds and rounds it to the nearest smaller unit of time.

Example:

```
s = Second(90)
result = compact(s)  # returns Minute(1) since 90 seconds can be compacted to 1 minute
```
"""
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

@doc """Compute the number of tf1 timeframes that are contained within tf2 timeframes.

$(TYPEDSIGNATURES)

tf1 and tf2 should be TimeFrame objects of different types.

Example:

```julia
tf1 = TimeFrame(Second(1))
tf2 = TimeFrame(Minute(1))
count = Base.count(tf1, tf2)  # returns the number of seconds in a minute
```
"""
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
