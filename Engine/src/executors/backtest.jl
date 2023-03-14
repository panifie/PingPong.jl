module Backtest
using Processing.Alignments
using ..Executors: Executors
using ..Executors.Engine.Types
using ..Executors.Engine.Strategies: Strategy, warmup, ping!
using ..Executors.Engine.Simulations: Simulations as sim

@doc """Backtest a strategy `strat` using context `ctx` iterating according to the specified timeframe.

On every iteration, the strategy is queried for the _current_ timestamp.
The strategy should only access data up to this point.
Example:
- Timeframe iteration: `1s`
- Strategy minimum available timeframe `1m`
Iteration gives time `1999-12-31T23:59:59` to the strategy:
The strategy (that can only lookup up to `1m` precision)
looks-up data until the timestamp `1999-12-31T23:58:00` which represents the
time until `23:59:00`.
Therefore we have to shift by one period down, the timestamp returned by `apply`:
```julia
julia> t = TimeTicks.apply(tf"1m", dt"1999-12-31T23:59:59")
1999-12-31T23:59:00 # we should not access this timestamp
julia> t - tf"1m".period
1999-12-31T23:58:00 # this is the correct candle timestamp that we can access
```
To avoid this mistake, use the function `available(::TimeFrame, ::DateTime)`, instead of apply.
"""
function backtest!(strat::Strategy, ctx::Context; trim_universe=false, doreset=true)
    # ensure that universe data start at the same time
    if trim_universe
        let data = flatten(strat.universe)
            !check_alignment(data) && trim!(data)
        end
    end
    if doreset
        reset(ctx.range, ctx.range.start + warmup(strat))
        resethistory!(strat)
    end
    for date in ctx.range
        ping!(strat, date, ctx)
    end
end

@doc "Backtest with context of all data loaded in the strategy universe."
backtest!(strat; kwargs...) = backtest!(strat, Context(strat); kwargs...)

@doc "Called from the strategy, tells the executor to process "
function Executors.pong!(s::Strategy{Sim}, ctx, args...; kwargs...)
    for o in s.orders
        # Each order
        cdl = last_candle(o.asset, o.date)
        # spread = sim.spread(cdl.high, cdl.low, cdl.close)
    end
end

export backtest!

end
