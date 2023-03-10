module Example
using Engine
using Engine.Strategies
using Instruments
using ExchangeTypes
using Misc: config
using Data.DataFramesMeta

# NOTE: do not export anything
import Engine.Strategies: marketsid, load, exchange, process

const name = :Example
const exc = ExchangeID(:kucoinfutures)
const S = Strategy{name,exc}

@doc "Module initialization."
function __init__() end

exchange(::Type{S}) = exc
exchange(::S) = exchange(S)
function load(::Type{S}, cfg)
    pairs = marketsid(S)
    Strategy(Example, pairs, cfg)
end

function process(s::S, ts, orders, trades)
    @eachrow s.universe.data begin
        isbuy(s, :instance, ts)
    end
end
process(s::S, ts) = begin
    process(s, ts, (), ())
end

function marketsid(::Type{S})
    ["ETH/USDT:USDT", "BTC/USDT:USDT", "XMR/USDT:USDT"]
end
marketsid(::S) = marketsid(S)

function assets(_::S)
    exc = ExchangeID(exc)
    Dict{Asset,ExchangeID}(Asset(a) => exc for a in marketsid(S))
end

function isbuy(Strategy::S, ai, ts)
    for (tf, data) in ai.data
        println(tf)
    end
end

end
