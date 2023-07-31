using Python: pyCached, Python
import Python: pytofloat

@doc "Clear all python dependent caches."
function emptycaches!()
    empty!(tickers_cache)
    empty!(tickersCache10Sec)
    empty!(marketsCache1Min)
    empty!(activeCache1Min)
    empty!(pyCached)
    ExchangeTypes._closeall()
end

pytofloat(v::N) where {N<:Number} = v
pytofloat(v::Py) = Python.pytofloat(v, zero(DFT))
