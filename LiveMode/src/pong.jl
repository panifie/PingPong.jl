using .Executors: WatchOHLCV
using .SimMode: _init_data
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

function pong!(
    f::Function,
    s::RTStrategy,
    ::InitData;
    cols::Tuple{Vararg{Symbol}},
    timeframe=s.timeframe,
)
    _init_data(f, s, cols...; timeframe)
    updated_at!(s, cols)
end
