
using Misc: config, PairData
using Dates: DateTime

include("types.jl")

function backtest(strategy::Function, pairs::Vector{PairData}, context::Context)
    portfolio = Portfolio()
    for candle in pairs[context.from_date:context.to_date]
        for pair in pairs
            signals = strategy(pair, portfolio, candle)
            if is_tradeable(pair)
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
end
