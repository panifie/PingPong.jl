using Instances
import Instances: committed, PositionOpen, PositionClose
using OrderTypes:
    LimitOrderType, PositionSide, ExchangeID, ShortSellOrder, FOKOrderType, IOCOrderType
using Strategies: NoMarginStrategy
using Base: negate
using Misc: Long, Short
using Lang: @ifdebug
import Base: fill!

const IncreaseLimitOrder{A,E} = Union{LimitOrder{Buy,A,E},ShortLimitOrder{Sell,A,E}}
const ReduceLimitOrder{A,E} = Union{LimitOrder{Sell,A,E},ShortLimitOrder{Buy,A,E}}

const LimitTrade{S,A,E} = Trade{<:LimitOrderType{S},A,E,Long}
const ShortLimitTrade{S,A,E} = Trade{<:LimitOrderType{S},A,E,Short}
const LimitBuyTrade{A,E} = LimitTrade{Buy,A,E}
const LimitSellTrade{A,E} = LimitTrade{Sell,A,E}
const ShortLimitBuyTrade{A,E} = ShortLimitTrade{Buy,A,E}
const ShortLimitSellTrade{A,E} = ShortLimitTrade{Sell,A,E}
const IncreaseLimitTrade{A,E} = Union{LimitBuyTrade{A,E},ShortLimitSellTrade{A,E}}
const ReduceLimitTrade{A,E} = Union{LimitSellTrade{A,E},ShortLimitBuyTrade{A,E}}

function limitorder(
    s::Strategy,
    ai,
    amount;
    date,
    type,
    price=priceat(s, type, ai, date),
    take=nothing,
    stop=nothing,
    kwargs...,
)
    @price! ai price take stop
    @amount! ai amount
    comm = committment(type, ai, price, amount)
    if iscommittable(s, type, comm, ai)
        basicorder(ai, price, amount, comm, SanitizeOff(); date, type, kwargs...)
    end
end

@doc "Remove a limit order from orders queue if it is filled."
aftertrade!(s::Strategy, ai, o::AnyLimitOrder) =
    if isfilled(ai, o)
        decommit!(s, o, ai)
        delete!(s, ai, o)
    end

_cashfrom(s, _, o::IncreaseOrder) = st.freecash(s) + committed(o)
_cashfrom(_, ai, o::ReduceOrder) = st.freecash(ai, orderpos(o)()) + committed(o)

@doc "Unconditionally deques immediate orders."
function aftertrade!(s::Strategy, ai, o::Union{AnyFOKOrder,AnyIOCOrder})
    decommit!(s, o, ai)
    delete!(s, ai, o)
    isfilled(ai, o) || st.ping!(s, o, NotEnoughCash(_cashfrom(s, ai, o)), ai)
end

function islastfill(ai::AssetInstance, t::Trade{<:LimitOrderType})
    let o = t.order
        t.amount != o.amount && isfilled(ai, o)
    end
end
function isfirstfill(::AssetInstance, t::Trade{<:LimitOrderType})
    let o = t.order
        attr(o, :unfilled)[] == negate(t.amount)
    end
end

@doc "Add a limit order to the pending orders of the strategy."
function queue!(s::Strategy, o::Order{<:LimitOrderType{S}}, ai) where {S<:OrderSide}
    # This is already done in general by the function that creates the order
    iscommittable(s, o, ai) || return false
    push!(s, ai, o)
    @deassert hasorders(s, ai, orderpos(o))
    commit!(s, o, ai)
    hold!(s, ai, o)
    return true
end

