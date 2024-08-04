using .st: IsolatedStrategy

using .Executors: AnyMarketOrder
using SimMode: singlewaycheck

@doc """Creates a paper market order, updating a leveraged position.

$(TYPEDSIGNATURES)

The function creates a paper market order for a given strategy, asset, and order type. 
It specifies the amount and date of the order. 
Additional keyword arguments can be passed.

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
    !singlewaycheck(s, ai, t) && return nothing
    fees_kwarg, order_kwargs = splitkws(:fees; kwargs)
    o, obside = create_paper_market_order(s, t, ai; amount, date, price, order_kwargs...)
    isnothing(o) && return nothing
    trade = marketorder!(s, o, ai; obside, date, fees_kwarg...)
    trade
end

@doc """Creates a simulated limit order.

$(TYPEDSIGNATURES)

The function creates a simulated limit order for a given strategy, asset, and order type.
It specifies the amount and date of the order. 
Additional keyword arguments can be passed.

"""
function pong!(
    s::IsolatedStrategy{Paper}, ai, t::Type{<:AnyLimitOrder}; amount, date, kwargs...
)
    !singlewaycheck(s, ai, t) && return nothing
    create_paper_limit_order!(s, ai, t; amount, date, kwargs...)
end

@doc """ Closes positions for a live margin strategy.

$(TYPEDSIGNATURES)

Initiates asynchronous position closing for each asset instance in the strategy's universe. """
function pong!(
    s::MarginStrategy{<:Union{Paper,Live}}, bp::ByPos, date, ::PositionClose; kwargs...
)
    @sync for ai in s.universe
        @async pong!(s, ai, bp, date, PositionClose(); kwargs...)
    end
end
