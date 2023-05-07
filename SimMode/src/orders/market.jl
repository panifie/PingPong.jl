function _create_sim_market_order(s, t, ai; amount, date, kwargs...)
    o = marketorder(s, ai, amount; type=t, date, kwargs...)
    isnothing(o) && return nothing
    iscommittable(s, o, ai) || return nothing
    return o
end

@doc "Executes a market order at a particular time if there is volume."
function marketorder!(s::Strategy{Sim}, o::MarketOrder, ai, actual_amount; date, kwargs...)
    t = trade!(s, o, ai; price=openat(ai, date), date, actual_amount, kwargs...)
    isnothing(t) || hold!(s, ai, o)
    t
end

function marketorder!(s::IsolatedStrategy{Sim}, o::MarketOrder, ai, actual_amount; date, kwargs...)
    # liqprx = liqprice(orderpos(o), ai, committed(o), o.price, o)
    # liquidation!(ai, v, o)
    t = trade!(s, o, ai; price=openat(ai, date), date, actual_amount=amount, kwargs...)
    isnothing(t) && return nothing
    # NOTE: Usually an exchange checks before executing a trade if right after the trade
    # the position would be liquidated, and would prevent you to do such trade, however we
    # always check after the trade, and liquidate accordingly, this is pessimistic since
    # we can't ensure that all exchanges have such protections in place.
    position!(s, ai, t)
    hold!(s, ai, o)
    # check for liquidation
    if isliquidated(ai, o)
    end
end
