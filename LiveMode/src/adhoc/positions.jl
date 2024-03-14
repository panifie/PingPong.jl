function positions_func(exc::Exchange{ExchangeID{:bybit}}, ais; timeout, kwargs...)
    f = first(exc, :fetchPositionsWs, :fetchPositions)
    _execfunc_timeout(f, PyList(raw(ai) for ai in ais); timeout, kwargs...)
end

function positions_func(exc::Exchange{ExchangeID{:deribit}}, ais; timeout, kwargs...)
    f = first(exc, :fetchPositionsWs, :fetchPositions)
    resp = _execfunc_timeout(f; timeout, kwargs...)
    syms = Set(raw(ai) for ai in ais)
    if islist(resp)
        filterfrom!(resp) do p
            string(p.get("symbol")) ∈ syms
        end
    end
    return resp
end
