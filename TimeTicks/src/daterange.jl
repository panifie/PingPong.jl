import Base: length, iterate, collect
struct DateRange11
    current_date::Vector{DateTime}
    start::DateTime
    stop::DateTime
    step::Period
    function DateRange11(start::DateTime, stop::DateTime, step=Day(1))
        begin
            new([start], start, stop, step)
        end
    end
    function DateRange11(start::DateTime, stop::DateTime, tf::TimeFrame)
        begin
            new([start], start, stop, tf.period)
        end
    end
end
DateRange = DateRange11

Base.show(dr::DateRange) = begin
    Base.print("start: $(dr.start)\nstop:  $(dr.stop)\nstep:  $(dr.step)")
end
Base.display(dr::DateRange) = Base.show(dr)
iterate(dr::DateRange) = begin
    dr.current_date[1] = dr.start + dr.step
    (dr.start, dr)
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

@doc """Create a `DateRange` using notation `FROM..TO;STEP`.

example:
1999-..2000-;1d
1999-12-01..2000-02-01;1d
1999-12-01T12..2000-02-01T10;1d
"""
macro dtr_str(s::String)
    (from, tostep) = split(s, "..")
    (to, step) = split(tostep, ";")
    dr = DateRange(todatetime(from), todatetime(to), convert(TimeFrame, step))
    :($dr)
end

export DateRange, @dtr_str
