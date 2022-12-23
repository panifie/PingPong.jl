using Dates

@doc """The configuration against which a strategy is tested.
- `spread`: affects the weight of the spread calculation (based on ohlcv)."
- `slippage`: affects the weight of the spread calculation (based on volume and trade size).
"""
struct Context3
    from_date::DateTime
    to_date::DateTime
    spread::Float64
    slippage::Float64
    Context3(from_date, to_date; spread=1.0, slippage=1.0) = begin
        new(from_date, to_date, spread, slippage)
    end
    Context3(since::Period; kwargs...) = begin
        to = now()
        from = to - since
        Context3(from, to; kwargs...)
    end
end
Context = Context3
