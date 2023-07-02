using SimMode: create_sim_limit_order, limitorder_ifprice!, hold!
using .st: NoMarginStrategy
using .OrderTypes: LimitOrderType, AtomicOrderType

@doc "Creates a paper market order."
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
    marketorder!(s, t, ai; date, obside)
end

@doc "Creates a simulated limit order."
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
