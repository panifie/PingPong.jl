using Misc
using TimeTicks
using Strategies: Strategy


# TYPENUM
@doc """The configuration against which a strategy is tested.
- `range`: The date range to backtest around.
"""
struct Context10{M<:ExecMode}
    range::DateRange
    function Context10(::M, d::DateRange; kwargs...) where {M<:ExecMode}
        new{M}(d)
    end
    function Context10(mode, tf, from_date, to_date; kwargs...)
        Context10(mode, DateRange(from_date, to_date, tf); kwargs...)
    end
    function Context10(
        mode, timeframe::T, from_date::T, to_date::T; kwargs...
    ) where {T<:AbstractString}
        from = convert(DateTime, from_date)
        to = convert(DateTime, to_date)
        tf = convert(TimeFrame, timeframe)
        Context10(mode, DateRange(tf, from, to); kwargs...)
    end
    function Context10(mode, tf::TimeFrame, since::Period)
        to = now()
        from = to - since
        Context10(mode, DateRange(from, to, tf))
    end
    Context10(mode, tf::TimeFrame, since::Integer) = begin
        from = abs(since) * tf.period
        Context10(mode, tf, from)
    end
end
Context = Context10

@doc "Creates a context within the available data loaded into the strategy universe with the smallest timeframe available."
Executors.Context(s::Strategy{<:ExecMode}) = begin
    dr = DateRange(s.universe)
    Executors.Context(execmode(s), dr)
end

export Context, ExecAction
