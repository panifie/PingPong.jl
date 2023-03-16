import Data: candleat

function candleat(ai::AssetInstance, date, tf)
    candleat(ai.data[tf], date)
end

function candleat(s::Strategy, ai::AssetInstance, date; tf=s.timeframe)
    candleat(ai, date, tf)
end
