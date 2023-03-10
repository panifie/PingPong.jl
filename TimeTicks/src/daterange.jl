import Base: length, iterate, collect, reset
const OptDate = Union{Nothing,DateTime}
const DateTuple = NamedTuple{(:start, :stop),NTuple{2,DateTime}}
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

function Base.convert(::Type{DateTuple}, d::DateRange)
    DateTuple((
        @something(d.start, typemin(DateTime)), @something(d.stop, typemax(DateTime))
    ))
end

function Base.show(dr::DateRange)
    Base.print("start: $(dr.start)\nstop:  $(dr.stop)\nstep:  $(dr.step)\n")
end
Base.display(dr::DateRange) = Base.show(dr)
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

reset(dr::DateRange) = dr.current_date[1] = dr.start
reset(dr::DateRange, d) = dr.current_date[1] = d
function Base.isequal(dr1::DateRange, dr2::DateRange)
    dr1.start === dr2.start && dr1.stop === dr2.stop
end

@doc """Create a `DateRange` using notation `FROM..TO;STEP`.

example:
1999-..2000-;1d
1999-12-01..2000-02-01;1d
1999-12-01T12..2000-02-01T10;1d
"""
macro dtr_str(s::String)
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
    dr = DateRange(args...)
    :($dr)
end

export DateRange, DateTuple, @dtr_str
