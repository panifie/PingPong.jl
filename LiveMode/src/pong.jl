using .Executors: WatchOHLCV
# FIXME: ohlcv watch functions should be moved to the PaperMode module
pong!(s::RTStrategy, ::WatchOHLCV) = watch_ohlcv!(s)
function pong!(
    f::Function,
    s::RTStrategy,
    ::UpdateData;
    cols::Tuple{Vararg{Symbol}},
    timeframe=s.timeframe,
)
    update!(f, s, cols...; tf=timeframe)
end
function pong!(
    f::Function,
    s::RTStrategy,
    ai::AssetInstance,
    ::UpdateData;
    cols::Tuple{Vararg{Symbol}},
    timeframe=s.timeframe,
)
    update!(f, s, ai, cols...; tf=timeframe)
end
