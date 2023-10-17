using .Executors: WatchOHLCV
# FIXME: ohlcv watch functions should be moved to the PaperMode module
pong!(s::RTStrategy, ::WatchOHLCV) = watch_ohlcv!(s)
pong!(f::Function, s::RTStrategy, k::Symbol, ::UpdateData) = update!(f, s, k)
