module Macd
using Engine
using Pairs
using ExchangeTypes

function __init__()
end

function process(Strategy::Strategy{:Macd})
    @show "wow"
end

function assets(::Type{Strategy{:Macd}})
    exc = ExchangeID(:kucoin)
    Dict{Asset,ExchangeID}(
        Asset(a) => exc
        for a in ["ETH/USDT", "BTC/USDT", "XMR/USDT"]
    )
end

export process, assets
end
