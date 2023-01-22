using Misc
using TimeTicks

@doc """The configuration against which a strategy is tested.
- `timeframe`: The time step or "tick" that the backtesting iteration uses.
- `spread`: affects the weight of the spread calculation (based on ohlcv)."
- `slippage`: affects the weight of the spread calculation (based on volume and trade size).
"""
struct Context8
    range::DateRange
    spread::Float64
    slippage::Float64
    Context8(tf, from_date, to_date; spread=1.0, slippage=1.0) = begin
        current_date = [apply(tf, from_date)]
        new(tf, from_date, to_date, current_date, spread, slippage)
    end
    Context8(
        timeframe::T,
        from_date::T,
        to_date::T;
        spread=1.0,
        slippage=1.0,
    ) where {T<:AbstractString} = begin
        from = convert(DateTime, from_date)
        to = convert(DateTime, to_date)
        tf = convert(TimeFrame, timeframe)
        new(tf, from, to, spread, slippage)
    end
    Context8(tf::TimeFrame, since::Period) = begin
        to = now()
        from = to - since
        Context8(tf, from, to)
    end
end
Context = Context8

export next
