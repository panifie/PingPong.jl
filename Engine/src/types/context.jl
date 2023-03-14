using Misc
using TimeTicks

# TYPENUM
@doc """The configuration against which a strategy is tested.
- `range`: The date range to backtest around.
"""
struct Context10{M<:ExecMode}
    range::DateRange
    function Context10(d::DateRange, ::M; spread=1.0, slippage=1.0) where {M<:ExecMode}
        new{M}(d, spread, slippage)
    end
    function Context10(tf, from_date, to_date; kwargs...)
        Context10(DateRange(from_date, to_date, tf); kwargs...)
    end
    function Context10(
        timeframe::T, from_date::T, to_date::T; kwargs...
    ) where {T<:AbstractString}
        from = convert(DateTime, from_date)
        to = convert(DateTime, to_date)
        tf = convert(TimeFrame, timeframe)
        Context10(DateRange(tf, from, to); kwargs...)
    end
    Context10(tf::TimeFrame, since::Period) = begin
        to = now()
        from = to - since
        Context10(DateRange(from, to, tf))
    end
    Context10(tf::TimeFrame, since::Integer) = begin
        from = abs(since) * tf.period
        Context10(tf, from)
    end
end
Context = Context10

export Context
