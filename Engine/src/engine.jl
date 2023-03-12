using Reexport
using Misc: config
using Data: PairData
using TimeTicks

# include("consts.jl")
# include("funcs.jl")
include("types/types.jl")
include("checks/checks.jl")
include("sim/sim.jl")
include("live/live.jl")
include("strategies/strategies.jl");

@reexport using .Strategies;
using .Strategies
using .Collections
using .Orders
using .LiveOrders
using Misc
using Processing.Alignments
using .Sim
using .Instances

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
function backtest!(strat::Strategy, ctx::Context; trim_universe=false)
    # ensure that universe data start at the same time
    if trim_universe
        local data = flatten(strat.universe)
        !check_alignment(data) && trim!(data)
    end
    reset(ctx.range, ctx.range.start + warmup(strat))
    orders = Order[]
    trades = []
    for date in ctx.range
        process(strat, date, orders, trades)
    end
end

@doc "Backtest with context of all data loaded in the strategy universe."
backtest!(strat; kwargs...) = begin
    backtest!(strat, Context(strat); kwargs...)
end

function execute(strat::Strategy, orders::Vector{LiveOrder})
    for o in orders
        # Each order
        cdl = last_candle(o.asset, o.date)
        spread = Sim.spread(cdl.high, cdl.low, cdl.close)
    end
end

export backtest!
