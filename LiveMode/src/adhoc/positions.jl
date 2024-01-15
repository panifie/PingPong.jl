function positions_func(exc::Exchange{ExchangeID{:bybit}}, ais; timeout, kwargs...)
    pyfetch_timeout(first(exc, :fetchPositionsWs, :fetchPositions), PyList(raw(ai) for ai in ais); timeout, kwargs...)
end
