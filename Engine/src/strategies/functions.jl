function candleat(s::Strategy, ai::AssetInstance, date; cols=:, tf=s.timeframe)
    ai.data[tf][date, cols]
end

function candleat(s::Strategy, a::AbstractAsset, date; kwargs...)
    candleat(s, s.universe[a].instance[begin], date; kwargs...)
end
