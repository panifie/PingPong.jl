using Executors.Instances: leverage!, tradepos, leverage
using Executors: hasorders
import Executors: pong!

const _PROTECTIONS_WARNING = """
!!! warning "Protections"
    Usually an exchange checks before executing a trade if right after the trade
    the position would be liquidated, and would prevent you to do such trade, however we
    always check after the trade, and liquidate accordingly, this is pessimistic since
    we can't ensure that all exchanges have such protections in place.
"""

@doc "Creates a simulated limit order, updating a levarged position."
function pong!(s::IsolatedStrategy{Sim}, ai, t::Type{<:LimitOrder}; amount, kwargs...)
    o = _create_sim_limit_order(s, t, ai; amount, kwargs...)
    return if !isnothing(o)
        t = limitorder_ifprice!(s, o, o.date, ai)
        t isa Trade && position!(s, ai, t)
        t
    end
end

# @doc "Progresses a simulated limit order."
# function pong!(s::Strategy{Sim}, o::Order{<:LimitOrderType}, date::DateTime, ai; kwargs...)

@doc """"Creates a simulated market order, updating a levarged position.
$_PROTECTIONS_WARNING
"""
function pong!(
    s::IsolatedStrategy{Sim},
    ai::MarginInstance,
    t::Type{<:AnyMarketOrder};
    amount,
    date,
    kwargs...,
)
    o = _create_sim_market_order(s, t, ai; amount, date, kwargs...)
    isnothing(o) && return nothing
    t = marketorder!(s, o, ai, amount; date)
    isnothing(t) && return nothing
    t isa Trade && position!(s, ai, t)
    t
end

@doc "Closes a leveraged position."
function pong!(s::MarginStrategy{Sim}, ai, side, date, ::PositionClose)
    close_position!(s, ai, side, date)
    @deassert !isopen(ai, side)
end

@doc "Update position Leverage. Returns true if update was successful, false otherwise.

The leverage is not updated when the position has pending orders (and it will return false in such cases.)
"
function pong!(
    s::MarginStrategy{Sim}, ai::MarginInstance, lev, ::UpdateLeverage; pos::PositionSide
)
    if hasorders(s, ai, pos)
        false
    else
        leverage!(ai, lev, pos)
        @deassert isapprox(leverage(ai, pos), lev, atol=1e-4)
        true
    end
end
