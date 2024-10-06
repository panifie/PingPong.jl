import Base: length, iterate, collect

@doc """A type representing a date range.

$(FIELDS)

This type is used to store information about a range of dates, including the current date within the range, the start and stop dates, and the step size between dates.

"""
struct DateRange
    current_date::Vector{OptDate}
    start::OptDate
    stop::OptDate
    step::Union{Nothing,Period}
    function DateRange(start::OptDate=nothing, stop::OptDate=nothing, step=nothing)
        new([start], start, stop, step)
    end
    function DateRange(start::OptDate, stop::OptDate, tf::TimeFrame)
        new([start], start, stop, tf.period)
    end
end

@doc """Convert a DateRange object d to a DateTuple object.

$(TYPEDSIGNATURES)

Example:

```julia
d = DateRange(Date(2022, 1, 1), Date(2022, 12, 31))
date_tuple = convert(DateTuple, d)  # returns a DateTuple with the start and stop dates of the DateRange
```
"""
function Base.convert(::Type{DateTuple}, d::DateRange)
    DateTuple((
        @something(d.start, typemin(DateTime)), @something(d.stop, typemax(DateTime))
    ))
end

Base.similar(dr::DateRange) = begin
    DateRange(dr.start, dr.stop, dr.step)
end

function Base.print(io::IO, dr::DateRange)
    print(io, "start: ", dr.start, "\nstop:  ", dr.stop, "\nstep:  ", dr.step, "\n")
end
Base.display(dr::DateRange) = Base.print(dr)
iterate(dr::DateRange) = begin
    @assert !isnothing(dr.start) && !isnothing(dr.stop)
    this = @something dr.current_date[1] dr.start
    dr.current_date[1] = this + dr.step
    (this, dr)
end

iterate(dr::DateRange, ::DateRange) = begin
    now = dr.current_date[1]
    dr.current_date[1] += dr.step
    dr.current_date[1] > dr.stop && return nothing
    (now, dr)
end

length(dr::DateRange) = begin
    (dr.stop - dr.start) ÷ dr.step
end

collect(dr::DateRange) = begin
    out = []
    for d in dr
        push!(out, d)
    end
    out
end

@doc "Starts the current date of the DateRange (defaults to `start` value.)"
current!(dr::DateRange, d=dr.start) = dr.current_date[1] = d
function Base.isequal(dr1::DateRange, dr2::DateRange)
    dr1.start === dr2.start && dr1.stop === dr2.stop
end

function Base.isapprox(dr1::DateRange, dr2::DateRange)
    dr1.start >= dr2.start && dr1.stop <= dr2.stop
end

function Base.parse(::Type{DateRange}, s::AbstractString)
    local to = step = ""
    (from, tostep) = split(s, "..")
    if !isempty(tostep)
        try
            (to, step) = split(tostep, ";")
        catch error
            if error isa BoundsError
                to = tostep
                step = ""
            else
                rethrow(error)
            end
        end
    end
    args::Vector{Any} = [isempty(v) ? nothing : todatetime(v) for v in (from, to)]
    if !isempty(step)
        push!(args, convert(TimeFrame, step))
    end
    DateRange(args...)
end

@doc """Create a `DateRange` using notation `FROM..TO;STEP`.

example:
1999-..2000-;1d
1999-12-01..2000-02-01;1d
1999-12-01T12..2000-02-01T10;1d
"""
macro dtr_str(s::String)
    :($(Base.parse(DateRange, s)))
end

export DateRange, DateTuple, @dtr_str, current!
