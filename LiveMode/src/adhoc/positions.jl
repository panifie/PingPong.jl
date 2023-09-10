function positions_func(exc::Exchange{ExchangeID{:bybit}}, ais; kwargs...)
    pyfetch(first(exc, :fetchPositionsWs, :fetchPositions), PyList(raw(ai) for ai in ais); kwargs...)
end
