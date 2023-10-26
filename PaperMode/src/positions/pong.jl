using .st: IsolatedStrategy

using .Executors: AnyMarketOrder
using SimMode: position!

@doc """"Creates a paper market order, updating a levarged position.
"""
function pong!(
    s::IsolatedStrategy{Paper},
    ai::MarginInstance,
    t::Type{<:AnyMarketOrder};
    amount,
    date,
    price=NaN,
    kwargs...,
)
    isopen(ai, opposite(positionside(t))) && return nothing
    o, obside = create_paper_market_order(s, t, ai; amount, date, price, kwargs...)
    isnothing(o) && return nothing
    trade = marketorder!(s, o, ai; obside, date)
    trade isa Trade && position!(s, ai, trade)
    trade
end

@doc "Creates a simulated limit order."
function pong!(
    s::IsolatedStrategy{Paper},
    ai,
    t::Type{<:Order{<:LimitOrderType}};
    amount,
    date,
    kwargs...,
)
    isopen(ai, opposite(positionside(t))) && return nothing
    limitorder!(s, ai, t; amount, date, kwargs...)
end
