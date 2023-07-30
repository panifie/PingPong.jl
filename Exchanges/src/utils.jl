using Python: pyCached, Python

@doc "Clear all python dependent caches."
function emptycaches!()
    empty!(tickers_cache)
    empty!(tickersCache10Sec)
    empty!(marketsCache1Min)
    empty!(activeCache1Min)
    empty!(pyCached)
    ExchangeTypes._closeall()
end

Python.pytofloat(v) = Python.pytofloat(v, zero(DFT))
