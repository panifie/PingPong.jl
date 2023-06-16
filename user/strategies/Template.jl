module Template

using PingPong
@strategyenv!
# @contractsenv!
# @optenv!

# const NAME = :Template
# const EXCID = ExchangeID(:exchage_sym)
const S{M} = Strategy{M,NAME,typeof(EXCID),NoMargin}
const TF = tf"1m"
__revise_mode__ = :eval

function ping!(s::S, ::ResetStrategy) end

function ping!(::Type{<:S}, config, ::LoadStrategy)
    assets = marketsid(S)
    s = Strategy(@__MODULE__, assets; config)
    s
end

ping!(_::S, ::WarmupPeriod) = Day(1)

function ping!(s::T, ts::DateTime, _) where {T<:S}
    ats = available(s.timeframe, ts)
    foreach(s.universe) do ai
        nothing
    end
end

function marketsid(::Type{<:S})
    []
end

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
