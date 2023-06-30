function create_sim_market_order(
    s, t, ai; amount, date, price=priceat(s, t, ai, date), kwargs...
)
    o = marketorder(s, ai, amount; type=t, date, price, kwargs...)
    isnothing(o) && return nothing
    iscommittable(s, o, ai) || return nothing
    commit!(s, o, ai)
    return o
end

@doc "Executes a market order at a particular time if there is volume."
function marketorder!(
    s::Strategy{Sim},
    o::Order{<:MarketOrderType},
    ai,
    actual_amount;
    date,
    price=openat(ai, date),
    kwargs...,
)
    t = trade!(s, o, ai; date, price, actual_amount, kwargs...)
    isnothing(t) || hold!(s, ai, o)
    t
end
