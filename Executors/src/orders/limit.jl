using .Instances
import .Instances: committed, PositionOpen, PositionClose
using .OrderTypes:
    LimitOrderType, PositionSide, ExchangeID, ShortSellOrder, FOKOrderType, IOCOrderType
using Strategies: NoMarginStrategy
using Base: negate
using .Misc: Long, Short
using .Lang: @ifdebug
import Base: fill!

@doc "Union type representing limit order increase operations. Includes Buy and Sell Short orders."
const IncreaseLimitOrder{A,E} = Union{LimitOrder{Buy,A,E},ShortLimitOrder{Sell,A,E}}

@doc "Union type representing limit order reduction operations. Includes Sell and Buy Short orders."
const ReduceLimitOrder{A,E} = Union{LimitOrder{Sell,A,E},ShortLimitOrder{Buy,A,E}}

@doc "Type representing a limit trade, includes long position limit orders."
const LimitTrade{S,A,E} = Trade{<:LimitOrderType{S},A,E,Long}

@doc "Type representing a short limit trade, includes short position limit orders."
const ShortLimitTrade{S,A,E} = Trade{<:LimitOrderType{S},A,E,Short}

@doc "Type representing a limit buy trade, specific to long position buy limit orders."
const LimitBuyTrade{A,E} = LimitTrade{Buy,A,E}

@doc "Type representing a limit sell trade, specific to long position sell limit orders."
const LimitSellTrade{A,E} = LimitTrade{Sell,A,E}

@doc "Type representing a short limit buy trade, specific to short position buy limit orders."
const ShortLimitBuyTrade{A,E} = ShortLimitTrade{Buy,A,E}

@doc "Type representing a short limit sell trade, specific to short position sell limit orders."
const ShortLimitSellTrade{A,E} = ShortLimitTrade{Sell,A,E}

@doc "Union type representing limit trade increase operations. Includes Buy and Sell Short trades."
const IncreaseLimitTrade{A,E} = Union{LimitBuyTrade{A,E},ShortLimitSellTrade{A,E}}

@doc "Union type representing limit trade reduction operations. Includes Sell and Buy Short trades."
const ReduceLimitTrade{A,E} = Union{LimitSellTrade{A,E},ShortLimitBuyTrade{A,E}}

@doc """ Places a limit order in the strategy

$(TYPEDSIGNATURES)

This function places a limit order with specified parameters in the strategy `s`. The `type` argument specifies the type of the order. The `price` defaults to the current price at the given `date` if not provided. The `take` and `stop` arguments are optional and default to `nothing`. If `skipcommit` is true, the function will not commit the order. Additional arguments can be passed via `kwargs`.

"""
function limitorder(
    s::Strategy,
    ai,
    amount;
    date,
    type,
    price=priceat(s, type, ai, date),
    take=nothing,
    stop=nothing,
    skipcommit=false,
    kwargs...,
)
    @price! ai price take stop
    @amount! ai amount
    comm = Ref(committment(type, ai, price, amount))
    @debug "create limitorder:" ai = raw(ai) price amount comm[] is_comm = iscommittable(
        s, type, comm, ai
    )
    if skipcommit || iscommittable(s, type, comm, ai)
        basicorder(ai, price, amount, comm, SanitizeOff(); date, type, kwargs...)
    end
end

_cashfrom(s, _, o::IncreaseOrder) = st.freecash(s) + committed(o)
_cashfrom(_, ai, o::ReduceOrder) = st.freecash(ai, positionside(o)()) + committed(o)

@doc """ Checks if the provided trade is the last fill for the given asset instance.

$(TYPEDSIGNATURES)
"""
function islastfill(ai::AssetInstance, t::Trade{<:LimitOrderType})
    o = t.order
    t.amount != o.amount && isfilled(ai, o)
end
@doc """ Checks if the provided trade is the first fill for the given asset instance.

$(TYPEDSIGNATURES)
"""
function isfirstfill(::AssetInstance, t::Trade{<:LimitOrderType})
    o = t.order
    attr(o, :unfilled)[] == negate(t.amount)
end

@doc """ Adds a limit order to the pending orders of the strategy.

$(TYPEDSIGNATURES)

This function takes a strategy, a limit order of type LimitOrderType{S}, and an asset instance as arguments. It adds the limit order to the pending orders of the strategy. If `skipcommit` is set to false (default), the order is committed and held. Returns true if the order was successfully added, otherwise false.
"""
function queue!(
    s::Strategy, o::Order{<:LimitOrderType{S}}, ai; skipcommit=false
) where {S<:OrderSide}
    @debug "queue limitorder:" is_comm = iscommittable(s, o, ai)
    # This is already done in general by the function that creates the order
    skipcommit || iscommittable(s, o, ai) || return false
    push!(s, ai, o)
    @deassert hasorders(s, ai, positionside(o))
    skipcommit || commit!(s, o, ai)
    hold!(s, ai, o)
    return true
end
