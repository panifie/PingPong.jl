using .Executors: WatchOHLCV
# FIXME: ohlcv watch functions should be moved to the PaperMode module
pong!(s::Strategy{<:Union{Paper,Live}}, ::WatchOHLCV) = watch_ohlcv!(s)
