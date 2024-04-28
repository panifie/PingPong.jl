using .Python: pyis, pybuiltins

function ccxt_orders_func!(a, exc::Exchange{ExchangeID{:bybit}})
    a[:live_orders_func] = if has(exc, :fetchOrder)
        fetch_func = first(exc, :fetchOrderWs, :fetchOrder)
        @assert has(exc, (:fetchOpenOrders, :fetchClosedOrders))
        fetch_open_func = first(exc, :fetchOpenOrdersWs, :fetchOpenOrders)
        fetch_closed_func = first(exc, :fetchClosedOrdersWs, :fetchClosedOrders)
        (ai; ids=(), side=BuyOrSell, kwargs...) -> let out = pylist()
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
        pyeq(Bool, Python.pytype(status), pybuiltins.str) && occursin("Pending", string(status))
    end

@doc "Sets up the [`fetch_open_orders`](@ref) or [`fetch_closed_orders`](@ref) closure for the ccxt exchange instance. (phemex)"
function ccxt_open_orders_func!(a, exc::Exchange{ExchangeID{:phemex}}; open=true)
    names = _func_syms(open)
    orders_func = first(exc, names.ws, names.fetch)
    eid = typeof(exchangeid(exc))
    a[names.key] = if !isnothing(orders_func)
        if open
            (ai; kwargs...) -> begin
                ans = _fetch_orders(ai, orders_func; eid, kwargs...)
                @debug "open/closed orders phemex: " ans
                if isnothing(ans)
                    return pylist()
                else
                    removefrom!(_phemex_ispending, ans)
                end
            end
        else
            open_names = _func_syms(true)
            open_orders_func = first(exc, open_names.ws, open_names.fetch)
            (ai; kwargs...) -> begin
                ot, ct = @sync begin
                    (@async _fetch_orders(ai, open_orders_func; eid, kwargs...)),
                    (@async _fetch_orders(ai, orders_func; eid, kwargs...))
                end
                canceled_ords = removefrom!(
                    _phemex_ispending,
                    @something(fetch(ot), pylist())
                )
                closed_ords = @something fetch(ct) pylist()
                closed_ords.extend(canceled_ords)
                closed_ords
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
