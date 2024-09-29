
function live_send_order(
    s::LiveStrategy{N,ExchangeID{:phemex}},
    ai::AssetInstance,
    t::Type{<:Order},
    args...;
    amount,
    price=lastprice(s, ai, t),
    stop_trigger=nothing,
    profit_trigger=nothing,
    stop_loss::Option{TriggerOrderTuple}=nothing,
    take_profit::Option{TriggerOrderTuple}=nothing,
    kwargs...,
) where {N}
    @price! ai stop_loss stop_trigger price profit_trigger take_profit
    if t <: ReduceOnlyOrder
        amount = min(ai.limits.amount.max, amount)
    else
        @amount! ai amount
    end
    invoke(live_send_order, Tuple{LiveStrategy,AssetInstance,Type{<:Order}}, s, ai, t, args...; amount, price, stop_trigger, profit_trigger, stop_loss, take_profit, kwargs...)
end

function create_order_func(exc::Exchange{ExchangeID{:binance}}, func, args...; params=LittleDict{Py,Any}(), kwargs...)
    postOnly = @pyconst "postOnly"
    timeInForce = @pyconst "timeInForce"
    if haskey(params, postOnly)
        if pytruth(pop!(params, postOnly))
            params[timeInForce] = @pyconst("PO")
        end
    end
    _execfunc(func, args...; params, kwargs...)
end
