using .Python: pyis, pybuiltins

function ccxt_orders_func!(a, exc::Exchange{ExchangeID{:bybit}})
    a[:live_orders_func] = if has(exc, :fetchOrder)
        fetch_func = first(exc, :fetchOrderWs, :fetchOrder)
        @assert has(exc, (:fetchOpenOrders, :fetchClosedOrders))
        fetch_open_func = first(exc, :fetchOpenOrdersWs, :fetchOpenOrders)
        fetch_closed_func = first(exc, :fetchClosedOrdersWs, :fetchClosedOrders)
        (ai; ids=(), side=Both, kwargs...) -> let out = pylist()
            sym = raw(ai)
            if isempty(ids)
                @sync begin
                    @async out.extend(_fetch_orders(ai, fetch_open_func; side, kwargs...))
                    @async out.extend(_fetch_orders(ai, fetch_closed_func; side, kwargs...))
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

_phemex_ispending(o) =
    let status = get_py(get_py(o, "info"), "execStatus")
        pyis(status, pybuiltins.str) && pyisTrue(@py "Pending" ∈ status)
    end
_func_syms(open) = begin
    oc = open ? "open" : "closed"
    cap = open ? "Open" : "Closed"
    func_sym = Symbol("fetch", cap, "Orders")
    func_sym_ws = Symbol("fetch", cap, "OrdersWs")
    func_key = Symbol("live_", oc, "_orders_func")
    (; func_sym, func_sym_ws, func_key)
end

@doc "Sets up the [`fetch_open_orders`](@ref) or [`fetch_closed_orders`](@ref) closure for the ccxt exchange instance. (phemex)"
function ccxt_open_orders_func!(a, exc::Exchange{ExchangeID{:phemex}}; open=true)
    func_sym, func_sym_ws, func_key = _func_syms(open)
    a[func_key] = if has(exc, func_sym)
        let f = first(exc, func_sym_ws, func_sym)
            if open
                (ai; kwargs...) -> let ans = _fetch_orders(ai, f; kwargs...)
                    @debug "open/closed orders phemex: " ans
                    if isnothing(ans)
                        return pylist()
                    else
                        _pyfilter!(ans, _phemex_ispending)
                    end
                end
            else
                open_f = first(exc, values(_func_syms(true))[1:2]...)
                (ai; kwargs...) -> begin
                    ot, ct = @sync begin
                        (@async _fetch_orders(ai, open_f; kwargs...)),
                        (@async _fetch_orders(ai, f; kwargs...))
                    end
                    cancelled_ords = _pyfilter!(@something(fetch(ot), pylist()), _phemex_ispending)
                    closed_ords = @something fetch(ct) pylist()
                    closed_ords.extend(cancelled_ords)
                    closed_ords
                end
            end
        end
    else
        fetch_func = get(a, :live_orders_func, nothing)
        @assert !isnothing(fetch_func) "`live_orders_func` must be set before `live_$(oc)_orders_func`"
        eid = typeof(exchangeid(exc))
        pred_func = o -> pyeq(Bool, resp_order_status(o, eid), @pyconst("open"))
        status_pred_func = if open
            (o) -> pred_func(o) && !_phemex_ispending(o)
        else
            !pred_func
        end
        (ai; kwargs...) -> let out = pylist()
            all_orders = fetch_func(ai; kwargs...)
            for o in all_orders
                status_pred_func(o) && out.append(o)
            end
            out
        end
    end
end
