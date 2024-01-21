function positions_func(exc::Exchange{ExchangeID{:bybit}}, ais; timeout, kwargs...)
    pyfetch_timeout(first(exc, :fetchPositionsWs, :fetchPositions), Returns(nothing), timeout, PyList(raw(ai) for ai in ais); kwargs...)
end

function positions_func(exc::Exchange{ExchangeID{:deribit}}, ais; timeout, kwargs...)
    resp = pyfetch_timeout(first(exc, :fetchPositionsWs, :fetchPositions), Returns(nothing), timeout, ; kwargs...)
    syms = Set(raw(ai) for ai in ais)
    if islist(resp)
        _pyfilter!(resp, (p) -> string(p.get("symbol")) ∈ syms)
    end
    return resp
end
