using Reexport
using Misc: config, PairData
using Dates: DateTime

# include("consts.jl")
# include("funcs.jl")
include("types/types.jl")
include("live/live.jl")
include("strategies/strategies.jl");
include("sim/sim.jl")

@reexport using .Strategies;
using .Strategies
using .Collections
using .Trades
using .Orders
using Misc
using Processing.Alignments

@doc "Backtest a strategy `strat` using context `ctx` iterating according to the specified timeframe."
function backtest!(strat::Strategy, ctx::Context; trim_universe=false)
    # ensure that universe data start at the same time
    if trim_universe
        local data = flatten(strat.universe)
        !check_alignment(data) && trim!(data)
    end
    reset(ctx)
    for date in ctx
        while true
            orders::Vector{LiveOrder} = process(strat, date)
            length(orders) == 0 && break
        end
        for pair in strat.universe
            for (signal, amount) in signals
                if signal < 0
                    sell(pair, portfolio, candle, amount, ctx)
                elseif signal > 0
                    buy(pair, portfolio, candle, amount, ctx)
                end
            end
        end
    end
end

@doc "Backtest passing a context arguments as a tuple."
backtest!(strat; ctx, kwargs...) = begin
    ctx = Context(ctx...)
    backtest!(strat, ctx; kwargs...)
end

include("sim/spread.jl")
using .Sim
execute(strat::Strategy, orders::Vector{LiveOrder}) =
    for o in orders
        cdl =
        spread = Sim.spread()
    end

export backtest!
