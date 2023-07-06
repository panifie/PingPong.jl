using Executors.Instances: leverage!, positionside, leverage
using Executors: hasorders
using .Lang: splitkws
import Executors: pong!

const _PROTECTIONS_WARNING = """
!!! warning "Protections"
    Usually an exchange checks before executing a trade if right after the trade
    the position would be liquidated, and would prevent you to do such trade, however we
    always check after the trade, and liquidate accordingly, this is pessimistic since
    we can't ensure that all exchanges have such protections in place.
"""

@doc "Creates a simulated limit order, updating a levarged position."
function pong!(
    s::IsolatedStrategy{Sim},
    ai::MarginInstance,
    t::Type{<:AnyLimitOrder};
    amount,
    kwargs...,
)
    isopen(ai, opposite(positionside(t))) && return nothing
    o = create_sim_limit_order(s, t, ai; amount, kwargs...)
    return if !isnothing(o)
        t = order!(s, o, o.date, ai)
        @deassert abs(committed(o)) > 0.0 || pricetime(o) ∉ keys(orders(s, ai, o))
        t
    end
end

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
    isopen(ai, opposite(positionside(t))) && return nothing
    fees_kwarg, order_kwargs = splitkws(:fees; kwargs)
    o = create_sim_market_order(s, t, ai; amount, date, order_kwargs...)
    isnothing(o) && return nothing
    t = marketorder!(s, o, ai, amount; date, fees_kwarg...)
    isnothing(t) && return nothing
    t isa Trade && position!(s, ai, t)
    t
end

@doc "Closes a leveraged position."
function pong!(s::MarginStrategy{<:Union{Paper,Sim}}, ai, side, date, ::PositionClose)
    close_position!(s, ai, side, date)
    @deassert !isopen(ai, side)
end

_lev_value(lev::Function) = lev()
_lev_value(lev) = lev

# TODO: implement leverage update mechanisms when position is open (and or has orders)
@doc "Update position leverage. Returns true if the update was successful, false otherwise.

The leverage is not updated when the position has pending orders or is open (and it will return false in such cases.)
"
function pong!(
    s::MarginStrategy{<:Union{Sim,Paper}},
    ai::MarginInstance,
    lev,
    ::UpdateLeverage;
    pos::PositionSide,
)
    if isopen(ai, pos) || hasorders(s, ai, pos)
        false
    else
        leverage!(ai, _lev_value(lev), pos)
        @deassert isapprox(leverage(ai, pos), _lev_value(lev), atol=1e-1) (
            leverage(ai, pos), lev
        )
        true
    end
end
