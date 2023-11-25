using .Executors: WatchOHLCV
using .SimMode: _init_data
# FIXME: ohlcv watch functions should be moved to the PaperMode module
@doc """ Executes the OHLCV watcher for a real-time strategy.

$(TYPEDSIGNATURES)

This function triggers the execution of the OHLCV (Open, High, Low, Close, Volume) watcher for a real-time strategy `s`.

"""
pong!(s::RTStrategy, ::WatchOHLCV) = watch_ohlcv!(s)
@doc """ Triggers the data update for a real-time strategy.

$(TYPEDSIGNATURES)

This function initiates the update of data for a real-time strategy `s`. The update is performed for the specified columns `cols` and uses the provided timeframe `timeframe`.

"""
function pong!(
    f::Function,
    s::RTStrategy,
    ::UpdateData;
    cols::Tuple{Vararg{Symbol}},
    timeframe=s.timeframe,
)
    update!(f, s, cols...; tf=timeframe)
end
@doc """ Triggers the data update for an asset instance in a real-time strategy.

$(TYPEDSIGNATURES)

This function triggers the update of data for a specific asset instance `ai` in a real-time strategy `s`. The update is performed for the specified columns `cols` and uses the provided timeframe `timeframe`.

"""
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

@doc """ Initializes the data for a real-time strategy.

$(TYPEDSIGNATURES)

This function initializes the data for a real-time strategy `s`. The initialization is performed for the specified columns `cols` and uses the provided timeframe `timeframe`. After the initialization, the `updated_at!` function is called to update the timestamp for the updated columns.

"""
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
