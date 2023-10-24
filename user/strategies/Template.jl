module Template

using PingPong
@strategyenv!
# @contractsenv!
# @optenv!

const DESCRIPTION = "Template"
const EXCID = ExchangeID(Symbol())
const S{M} = Strategy{M,nameof(@__MODULE__),typeof(EXCID),NoMargin}
const SC{E,M,R} = Strategy{M,nameof(@__MODULE__),E,R}
const TF = tf"1m"
__revise_mode__ = :eval

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

function ping!(::Type{<:SC}, ::StrategyMarkets)
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
