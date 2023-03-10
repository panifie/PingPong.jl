using Misc
using TimeTicks

# TYPENUM
@doc """The configuration against which a strategy is tested.
- `timeframe`: The time step or "tick" that the backtesting iteration uses.
- `spread`: affects the weight of the spread calculation (based on ohlcv)."
- `slippage`: affects the weight of the spread calculation (based on volume and trade size).
"""
struct Context9
    range::DateRange
    spread::Float64
    slippage::Float64
    Context9(d::DateRange; spread=1.0, slippage=1.0) = begin
        new(d, spread, slippage)
    end
    function Context9(tf, from_date, to_date; kwargs...)
        new(DateRange(from_date, to_date, tf), kwargs...)
    end
    function Context9(
        timeframe::T, from_date::T, to_date::T; kwargs...
    ) where {T<:AbstractString}
        from = convert(DateTime, from_date)
        to = convert(DateTime, to_date)
        tf = convert(TimeFrame, timeframe)
        new(DateRange(tf, from, to), kwargs...)
    end
    Context9(tf::TimeFrame, since::Period) = begin
        to = now()
        from = to - since
        Context9(DateRange(from, to, tf))
    end
    Context9(tf::TimeFrame, since::Integer) = begin
        from = abs(since) * tf.period
        Context9(tf, from)
    end
end
Context = Context9
