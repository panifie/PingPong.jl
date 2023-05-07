@doc "Creates a simulated limit order, updating a levarged position."
function pong!(
    s::IsolatedStrategy{Sim}, t::Type{<:LimitOrder}, ai; amount, kwargs...
)
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
    s::IsolatedStrategy{Sim}, t::Type{<:MarketOrder}, ai; amount, kwargs...
)
    t = _create_sim_market_order(s, t, ai; amount, kwargs...)
    return if !isnothing(t)
        position!(s, ai, t)
    end
end
