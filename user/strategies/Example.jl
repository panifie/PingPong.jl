module Example

using PingPong
@strategyenv!

const NAME = :Example
const EXCID = ExchangeID(:bybit)
const S{M} = Strategy{M,NAME,typeof(EXCID),NoMargin}
const TF = tf"1m"
__revise_mode__ = :eval

include("common.jl")

# function __init__() end

function ping!(::Type{S}, ::LoadStrategy, config)
    assets = marketsid(S)
    s = Strategy(@__MODULE__, assets; config)
    s.attrs[:buydiff] = 1.01
    s.attrs[:selldiff] = 1.005
    s
end

ping!(_::S, ::WarmupPeriod) = Day(1)

function ping!(s::S, ts, _)
    pong!(s, ts, UpdateOrders())
    ats = available(tf"15m", ts)
    makeorders(ai) = begin
        if issell(s, ai, ats)
            sell!(s, ai, ats, ts)
        elseif isbuy(s, ai, ats)
            buy!(s, ai, ats, ts)
        end
    end
    foreach(makeorders, s.universe.data.instance)
end

function marketsid(::Type{S})
    ["ETH/USDT:USDT", "BTC/USDT:USDT", "XMR/USDT:USDT"]
end

end
