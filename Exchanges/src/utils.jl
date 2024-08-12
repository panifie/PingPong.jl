using .Python: pyCached
import .Python: pytofloat

@doc "Clears all Python-dependent caches."
function emptycaches!()
    empty!(TICKERS_CACHE100)
    empty!(TICKERS_CACHE10)
    empty!(TICKERSLIST_LOCK_DICT)
    empty!(tickersCache10Sec)
    empty!(marketsCache1Min)
    empty!(activeCache1Min)
    empty!(pyCached)
    ExchangeTypes._closeall()
end

pytofloat(v::N) where {N<:Number} = v
pytofloat(v::Py) = Python.pytofloat(v, 0.0)
