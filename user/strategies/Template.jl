module Template
using PingPong

const DESCRIPTION = "Template"
const EXC = Symbol()
const MARGIN = NoMargin
const TF = tf"1m"

@strategyenv!
# @contractsenv!
# @optenv!

function ping!(s::SC, ::ResetStrategy) end

function ping!(_::SC, ::WarmupPeriod)
    Day(1)
end

function ping!(s::SC, ts::DateTime, _)
    ats = available(s.timeframe, ts)
    foreach(s.universe) do ai
        nothing
    end
end

function ping!(::Union{<:SC,Type{<:SC}}, ::StrategyMarkets)
    String[]
end

# function ping!(t::Type{<:SC}, config, ::LoadStrategy)
# end

## Optimization
# function ping!(s::S, ::OptSetup)
#     (;
#         ctx=Context(Sim(), tf"15m", dt"2020-", now()),
#         params=(),
#         # space=(kind=:MixedPrecisionRectSearchSpace, precision=Int[]),
#     )
# end
# function ping!(s::S, params, ::OptRun) end

# function ping!(s::S, ::OptScore)::Vector
#     [stats.sharpe(s)]
# end

end
