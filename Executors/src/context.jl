using .Misc
using .TimeTicks
using Strategies: Strategy
import .Misc: execmode

@doc """The configuration against which a strategy is tested.

$(TYPEDSIGNATURES)

The `Context` struct has the following type parameter:

- `M`: a subtype of `ExecMode`.

The struct has the following fields:
- `range`: The date range to backtest around.

"""
struct Context{M<:ExecMode}
    range::DateRange
    function Context(::M, d::DateRange; kwargs...) where {M<:ExecMode}
        new{M}(d)
    end
    function Context(mode, tf, from_date, to_date; kwargs...)
        Context(mode, DateRange(from_date, to_date, tf); kwargs...)
    end
    function Context(
        mode, timeframe::T, from_date::T, to_date::T; kwargs...
    ) where {T<:AbstractString}
        from = convert(DateTime, from_date)
        to = convert(DateTime, to_date)
        tf = convert(TimeFrame, timeframe)
        Context(mode, DateRange(tf, from, to); kwargs...)
    end
    function Context(mode, tf::TimeFrame, since::Period)
        to = now()
        from = to - since
        Context(mode, DateRange(from, to, tf))
    end
    Context(mode, tf::TimeFrame, since::Integer) = begin
        from = abs(since) * tf.period
        Context(mode, tf, from)
    end
end

@doc """Create an instance of `Context` for a given strategy using the shortest timeframe.

$(TYPEDSIGNATURES)

The `Context` function takes the following parameters:

- `s`: a Strategy object of subtype `ExecMode`.
"""
Executors.Context(s::Strategy{<:ExecMode}) = begin
    dr = DateRange(s.universe)
    Executors.Context(execmode(s), dr)
end

execmode(::Context{M}) where {M} = M

Base.similar(ctx::Context) = Context(execmode(ctx)(), similar(ctx.range))

export Context
