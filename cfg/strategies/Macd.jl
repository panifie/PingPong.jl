module MacdStrategy
using Engine
using Instruments
using ExchangeTypes
using Misc: config

const name = :Macd
const S = Strategy{name}
const exc = :kucoinfutures

@doc "Module initialization."
function __init__() end

function process(Strategy::S, idx, cdl)
    Order()
end

function marketids(::Type{S})
    ["ETH/USDT:USDT", "BTC/USDT:USDT", "XMR/USDT:USDT"]
end

function assets(_::S)
    exc = ExchangeID(exc)
    Dict{Asset,ExchangeID}(Asset(a) => exc for a in pairs(S))
end

export name, process, assets, marketids
end
