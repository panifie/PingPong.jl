using Python: pyCached

@doc "Clear all python dependent caches."
function emptycaches!()
    empty!(tickers_cache)
    empty!(tickersCache1Min)
    empty!(marketsCache1Min)
    empty!(activeCache1Min)
    empty!(pyCached)
    empty!(exchanges)
    empty!(sb_exchanges)
end
