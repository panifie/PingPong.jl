
_nameof(f::Py) =
    if hasproperty(f, :__name__)
        string(getproperty(f, :__name__))
    end
_nameof(f::Function) = string(nameof(f))
function _cancel_orders(ai::AssetInstance{<:AbstractAsset,<:eids(:binance)}, side, ids, orders_f, cancel_multi_f)
    exc = exchange(ai)
    if !isnothing(match(r"cancel_?orders"i, _nameof(cancel_multi_f)))
        mkt_type = markettype(exc, raw(ai), marginmode(ai))
        if mkt_type != :swap
            cancel_single_f = first(exchange(ai), :cancelOrderWs, :cancelOrder)
            cancel_multi_f = cancel_loop_func(exc, cancel_single_f)
        end
    end
    tp = Tuple{Any,Any,Any,Any,Any}
    invoke(_cancel_orders, tp, ai, side, ids, orders_f, cancel_multi_f)
end
