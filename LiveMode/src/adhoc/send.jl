
function live_send_order(
    s::LiveStrategy{N,ExchangeID{:phemex}},
    ai,
    t,
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
    @amount! ai amount
    invoke(live_send_order, Tuple{LiveStrategy, AssetInstance, UnionAll}, s, ai, t, args...; amount, price, stop_trigger, profit_trigger, stop_loss, take_profit, kwargs...)
end
