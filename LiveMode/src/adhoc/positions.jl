function positions_func(exc::Exchange{ExchangeID{:bybit}}, ais; kwargs...)
    pyfetch(first(exc, :fetchPositionsWs, :fetchPositions); kwargs...)
end
