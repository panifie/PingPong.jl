using SimMode: create_sim_limit_order, limitorder_ifprice!, hold!
using .st: NoMarginStrategy
using .OrderTypes: LimitOrderType, ImmediateOrderType


@doc """Creates a paper market order.

$(TYPEDSIGNATURES)

The function creates a paper market order for a given strategy and asset. 
It specifies the amount of the order and the type of order (e.g., limit order, immediate order).

"""
function pong!(
    s::NoMarginStrategy{Paper},
    ai,
    t::Type{<:AnyMarketOrder};
    amount,
    date,
    price=priceat(s, t, ai, nothing),
    kwargs...,
)
    o, obside = create_paper_market_order(s, t, ai; amount, date, price, kwargs...)
    isnothing(o) && return nothing
    marketorder!(s, o, ai; date, obside)
end

@doc """Creates a simulated limit order.

$(TYPEDSIGNATURES)

The function creates a simulated limit order for a given strategy and asset.
It specifies the amount of the order and the date. 
Additional keyword arguments can be passed.

"""
function pong!(
    s::NoMarginStrategy{Paper},
    ai,
    t::Type{<:Order{<:LimitOrderType}};
    amount,
    date,
    kwargs...,
)
    limitorder!(s, ai, t; amount, date, kwargs...)
end
