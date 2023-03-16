import Data: candleat

function candleat(ai::AssetInstance, date, tf; kwargs...)
    candleat(ai.data[tf], date; kwargs...)
end

function candleat(s::Strategy, ai::AssetInstance, date; tf=s.timeframe, kwargs...)
    candleat(ai, date, tf; kwargs...)
end
