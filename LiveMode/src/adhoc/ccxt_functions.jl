
function ccxt_orders_func!(a, exc::Exchange{ExchangeID{:bybit}})
    a[:live_orders_func] = if has(exc, :fetchOrder)
        fetch_func = first(exc, :fetchOrderWs, :fetchOrder)
        @assert has(exc, (:fetchOpenOrders, :fetchClosedOrders))
        fetch_open_func = first(exc, :fetchOpenOrdersWs, :fetchOpenOrders)
        fetch_closed_func = first(exc, :fetchClosedOrdersWs, :fetchClosedOrders)
        (ai; ids=(), kwargs...) -> let out = pylist()
            sym = raw(ai)
            if isempty(ids)
                @sync begin
                    @async out.extend(_fetch_orders(ai, fetch_open_func; kwargs...))
                    @async out.extend(_fetch_orders(ai, fetch_closed_func; kwargs...))
                end
            else
                @sync for id in ids
                    @async out.append(_execfunc(fetch_func, id, sym; kwargs...))
                end
            end
            out
        end
    else
        @warn "ccxt funcs: fetch orders not supported" exchange = nameof(exc)
    end
end
