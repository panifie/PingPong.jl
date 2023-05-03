module Example

using PingPong
@strategyenv!

const NAME = :Example
const EXCID = ExchangeID(:phemex)
const S{M} = Strategy{M,NAME,typeof(EXCID),NoMargin}
const TF = tf"1m"

__revise_mode__ = :eval
include("common.jl")

ping!(s::S, ::ResetStrategy) = _reset!(s)
function ping!(::Type{<:S}, ::LoadStrategy, config)
    assets = marketsid(S)
    s = Strategy(@__MODULE__, assets; config)
    _reset!(s)
    s
end

ping!(_::S, ::WarmupPeriod) = Day(1)

function ping!(s::T where {T<:S}, ts, _)
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

function marketsid(::Type{<:S})
    ["ETH/USDT", "BTC/USDT", "SOL/USDT"]
end

end
