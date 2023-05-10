using Executors.Instances: leverage!
import Executors: pong!

@doc "Creates a simulated limit order, updating a levarged position."
function pong!(s::IsolatedStrategy{Sim}, ai, t::Type{<:LimitOrder}; amount, kwargs...)
    o = _create_sim_limit_order(s, t, ai; amount, kwargs...)
    return if !isnothing(t)
        t = limitorder_ifprice!(s, o, o.date, ai)
        position!(s, ai, t)
    end
end

# @doc "Progresses a simulated limit order."
# function pong!(s::Strategy{Sim}, o::Order{<:LimitOrderType}, date::DateTime, ai; kwargs...)

@doc "Creates a simulated market order, updating a levarged position."
function pong!(
    s::IsolatedStrategy{Sim}, ai::MarginInstance, t::Type{<:MarketOrder}; amount, date, kwargs...
)
    o = _create_sim_market_order(s, t, ai; amount, date, kwargs...)
    isnothing(o) && return nothing
    t = marketorder!(s, o, ai, amount; date)
    isnothing(t) && return nothing
    # NOTE: Usually an exchange checks before executing a trade if right after the trade
    # the position would be liquidated, and would prevent you to do such trade, however we
    # always check after the trade, and liquidate accordingly, this is pessimistic since
    # we can't ensure that all exchanges have such protections in place.
    position!(s, ai, t)
end

@doc "Closes a leveraged position."
function pong!(s::MarginStrategy, ai, side, date, ::PositionClose)
    close_position!(s, ai, side, date)
    @deassert !isopen(ai, side)
end

@doc "Update position Leverage."
function pong!(ai::MarginInstance, lev, ::UpdateLeverage; pos::PositionSide)
    leverage!(ai, lev, pos)
    @deassert isapprox(leverage(ai, pos), lev, atol=1e-4)
end
