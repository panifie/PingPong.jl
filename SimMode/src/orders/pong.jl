import Executors: pong!
using Executors
using Executors: iscommittable
using OrderTypes: LimitOrderType, MarketOrderType
using Lang: @lget!

function _create_sim_limit_order(s, t, ai; amount, kwargs...)
    o = limitorder(s, ai, amount; type=t, kwargs...)
    isnothing(o) && return nothing
    queue!(s, o, ai) || return nothing
    limitorder_ifprice!(s, o, o.date, ai)
end

@doc "Creates a simulated limit order."
function pong!(s::Strategy{Sim}, t::Type{<:Order{<:LimitOrderType}}, ai; amount, kwargs...)
    _create_sim_limit_order(s, t, ai; amount, kwargs...)
end

@doc "Progresses a simulated limit order."
function pong!(s::Strategy{Sim}, o::Order{<:LimitOrderType}, date::DateTime, ai; kwargs...)
    limitorder_ifprice!(s, o, date, ai)
end

function _create_sim_market_order(s, t, ai; amount, date, kwargs...)
    o = marketorder(s, ai, amount; type=t, date, kwargs...)
    isnothing(o) && return nothing
    iscommittable(s, o, ai) || return nothing
    t = marketorder!(s, o, ai, amount; date, kwargs...)
    isnothing(t) || hold!(s, ai, o)
    t
end

@doc "Creates a simulated market order."
function pong!(
    s::Strategy{Sim}, t::Type{<:Order{<:MarketOrderType}}, ai; amount, date, kwargs...
)
    _create_sim_market_order(s, t, ai; amount, date, kwargs...)
end

_lastupdate!(s, date) = s.attrs[:sim_last_orders_update] = date
_lastupdate(s) = s.attrs[:sim_last_orders_update]

@doc "Iterates over all pending orders checking for new fills. Should be called only once, precisely at the beginning of a `ping!` function."
function pong!(s::Strategy{Sim}, date, ::UpdateOrders)
    _lastupdate(s) >= date &&
        error("Tried to update orders multiple times on the same date.")
    for (ai, ords) in s.sellorders
        for o in ords
            pong!(s, o, date, ai)
        end
    end
    for (ai, ords) in s.buyorders
        for o in ords
            pong!(s, o, date, ai)
        end
    end
    _lastupdate!(s, date)
end
