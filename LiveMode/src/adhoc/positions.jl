function positions_func(exc::Exchange{ExchangeID{:bybit}}, ais; timeout, kwargs...)
    f = first(exc, :fetchPositionsWs, :fetchPositions)
    list = PyList(raw(ai) for ai in ais)
    args = length(list) > 1 ? () : (list,)
    _execfunc_timeout(f, args...; timeout, kwargs...)
end

function positions_func(exc::Exchange{ExchangeID{:deribit}}, ais; timeout, kwargs...)
    f = first(exc, :fetchPositionsWs, :fetchPositions)
    resp = _execfunc_timeout(f; timeout, kwargs...)
    syms = Set(raw(ai) for ai in ais)
    if islist(resp)
        removefrom!(resp) do p
            string(p.get("symbol")) ∈ syms
        end
    end
    return resp
end

_resp_from_watcher(s::Strategy) = begin
    w = attr(s, :live_balance_watcher, nothing)
    if !(w isa Watcher) || isempty(w.buffer)
        return nothing
    end
    w.buffer[end].value
end
function _phemex_parse_positions(
    s::Strategy{<:ExecMode,<:Any,<:ExchangeID{:phemex}}, resp=_resp_from_watcher(s)
)
    positions = try
        resp["info"]["data"]["positions"]
    catch
        @warn "ccxt: failed to parse positions" resp
        return nothing
    end
    return exchange(s).parsePositions(positions)
end
