module MacdStrategy
using Engine
using Pairs
using ExchangeTypes
using Misc: config

const name = :Macd
const S = Strategy{name}
const exc = :kucoin

@doc "Module initialization."
function __init__()
end

function process(Strategy::S, idx, cdl)
    Order()
end

function get_pairs(::Type{S})
    ["ETH/USDT", "BTC/USDT", "XMR/USDT"]
end

function assets(_::S)
    exc = ExchangeID(:kucoin)
    Dict{Asset,ExchangeID}(
        Asset(a) => exc
        for a in pairs(S)
    )
end

export name, process, assets, get_pairs
end
