using .Executors: AnyLimitOrder

@doc "Creates a simulated limit order."
function pong!(s::NoMarginStrategy{Live}, ai, t::Type{<:AnyLimitOrder}; amount, kwargs...)
    o = create_sim_limit_order(s, t, ai; amount, kwargs...)
    isnothing(o) && return nothing
    limitorder_ifprice!(s, o, o.date, ai)
end

@doc "Cancel orders for a particular asset instance."
function pong!(
    s::Strategy{Live}, ai::AssetInstance, ::CancelOrders; t::Type{O}=Both
) where {O<:OrderSide}
    live_cancel(s, ai)
end
