module RandomStratIso
using PingPong

const DESCRIPTION = "RandomStratIso"
const EXC = :bybit
const TF = tf"1m"

@strategyenv!
@contractsenv!
# @optenv!
using Statistics: mean

function ping!(s::S, ::ResetStrategy) end

ping!(_::S, ::WarmupPeriod) = Day(1)

function ordertp(
    ai, ::BySide{O}=ifelse(P == Long, Buy, Sell), ::ByPos{P}=posside(ai)
) where {O,P}
    ifelse(P == Long, MarketOrder{O}, ShortMarketOrder{O})
end

function ping!(s::T, ts::DateTime, ctx) where {T<:SC}
    date = ts
    foreach(s.universe) do ai
        oside = rand((Buy, Sell))
        pside = rand((Long, Short))
        tp = ordertp(ai, oside, pside)
        if isopen(ai)
            if posside(ai) == pside
                tp = ordertp(ai, oside, pside)
                pong!(s, ai, tp; amount=float(ai) / 3, date)
            else
                this_pos = position(ai)
                this_side = posside(this_pos)
                while isopen(this_pos)
                    pong!(s, ai, this_side, date, PositionClose())
                end
                pong!(s, ai, tp; amount=ai.limits.amount.min, date)
            end
        elseif cash(s) > ai.limits.cost.min
            pong!(s, ai, tp; amount=ai.limits.amount.min, date)
        end
    end
end

function ping!(t::Type{<:SC}, config, ::LoadStrategy)
    assets = marketsid(t)
    config.margin = Isolated()
    sandbox = config.mode == Paper() ? false : config.sandbox
    s = Strategy(@__MODULE__, assets; config, sandbox)
    @assert marginmode(s) == config.margin
    @assert execmode(s) == config.mode
    s[:verbose] = false
    s
end

function ping!(::Type{<:SC}, ::StrategyMarkets)
    ["BTC/USDT:USDT", "ETH/USDT:USDT", "SOL/USDT:USDT"]
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
#     [mt.sharpe(s)]
# end

end
