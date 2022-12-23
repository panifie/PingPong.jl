
using Misc: config, PairData
using Dates: DateTime

# include("consts.jl")
# include("funcs.jl")
include("types/types.jl")
include("live/live.jl")
using .Strategies

function backtest!(strat::Strategy{T}, context::Context) where {T}
    for dt in enumerate(context.from_date:context.to_date)
        while true
            strat.universe[:]
            process(strat, universe)
        end
        for pair in strat.universe
            for (signal, amount) in signals
                if signal < 0
                    sell(pair, portfolio, candle, amount, context)
                elseif signal > 0
                    buy(pair, portfolio, candle, amount, context)
                end
            end
        end
    end
end
