
function ccxt_orders_func!(a, exc::Exchange{ExchangeID{:bybit}})
    a[:live_orders_func] = if has(exc, :fetchOrder)
        fetch_func = first(exc, :fetchOrderWs, :fetchOrder)
        (ai; ids, kwargs...) -> let out = pylist()
            sym = raw(ai)
            @sync for id in ids
                @async out.append(_execfunc(fetch_func, id, sym; kwargs...))
            end
            out
        end
    else
        @warn "ccxt funcs: fetch orders not supported" exchange = nameof(exc)
    end
end
