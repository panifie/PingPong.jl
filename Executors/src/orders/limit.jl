using Instances
import Instances: committed, PositionOpen, PositionClose
using OrderTypes: LimitOrderType, PositionSide, ExchangeID, ShortSellOrder
using Strategies: NoMarginStrategy
using Base: negate
using Misc: Long, Short

const IncreaseLimitOrder{A,E} = Union{LimitOrder{Buy,A,E},ShortLimitOrder{Sell,A,E}}
const ReduceLimitOrder{A,E} = Union{LimitOrder{Sell,A,E},ShortLimitOrder{Buy,A,E}}

const AnyLimitOrder{S<:OrderSide,P<:PositionSide} = Order{
    <:LimitOrderType{S},<:AbstractAsset,<:ExchangeID,P
}
const LimitTrade{S,A,E} = Trade{<:LimitOrderType{S},A,E,Long}
const ShortLimitTrade{S,A,E} = Trade{<:LimitOrderType{S},A,E,Short}
const LimitBuyTrade{A,E} = LimitTrade{Buy,A,E}
const LimitSellTrade{A,E} = LimitTrade{Sell,A,E}
const ShortLimitBuyTrade{A,E} = ShortLimitTrade{Buy,A,E}
const ShortLimitSellTrade{A,E} = ShortLimitTrade{Sell,A,E}
const IncreaseLimitTrade{A,E} = Union{LimitBuyTrade{A,E},ShortLimitSellTrade{A,E}}
const ReduceLimitTrade{A,E} = Union{LimitSellTrade{A,E},ShortLimitBuyTrade{A,E}}

function limit_order_state(
    take, stop, committed::Vector{T}, unfilled::Vector{T}, trades=Trade[]
) where {T<:Real}
    _BasicOrderState{T}((take, stop, committed, unfilled, trades))
end

function limitorder(
    ai::AssetInstance,
    price,
    amount,
    committed,
    ::SanitizeOff;
    type=GTCOrder{Buy},
    date,
    take=nothing,
    stop=nothing,
)
    ismonotonic(stop, price, take) || return nothing
    iscost(ai, amount, stop, price, take) || return nothing
    @deassert if type <: BuyOrder
        committed[] > ai.limits.cost.min
    else
        committed[] > ai.limits.amount.min
    end "Order committment too low\n$(committed[]), $(ai.asset) $date"
    let unfilled = unfillment(type, amount)
        @deassert type <: BuyOrder ? unfilled[] < 0.0 : unfilled[] > 0.0
        OrderTypes.Order(
            ai,
            type;
            date,
            price,
            amount,
            attrs=limit_order_state(take, stop, committed, unfilled),
        )
    end
end

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
        limitorder(ai, price, amount, comm, SanitizeOff(); date, type, kwargs...)
    end
end

# NOTE: unfilled is always negative
function Base.fill!(o::IncreaseLimitOrder, t::IncreaseLimitTrade)
    @deassert o isa BuyOrder && attr(o, :unfilled)[] <= 0.0
    @deassert committed(o) == o.attrs.committed[] && committed(o) >= 0.0
    attr(o, :unfilled)[] += t.amount # from neg to 0 (buy amount is pos)
    @deassert attr(o, :unfilled)[] <= 0
    attr(o, :committed)[] += t.size # from pos to 0 (buy size is neg)
    @deassert committed(o) >= 0
end
function Base.fill!(o::LimitOrder{Sell}, t::LimitSellTrade)
    @deassert o isa SellOrder && attr(o, :unfilled)[] >= 0.0
    @deassert committed(o) == o.attrs.committed[] && committed(o) >= 0.0
    attr(o, :unfilled)[] += t.amount # from pos to 0 (sell amount is neg)
    @deassert attr(o, :unfilled)[] >= 0
    attr(o, :committed)[] += t.amount # from pos to 0 (sell amount is neg)
    @deassert committed(o) >= 0
end
function Base.fill!(o::ShortLimitOrder{Buy}, t::ShortLimitBuyTrade)
    @deassert o isa ShortBuyOrder && attr(o, :unfilled)[] >= 0.0
    @deassert committed(o) == o.attrs.committed[] && committed(o) >= 0.0
    @deassert attr(o, :unfilled)[] < 0.0
    attr(o, :unfilled)[] += t.amount # from pos to 0 (sell amount is neg)
    @deassert attr(o, :unfilled)[] >= 0
    # NOTE: committment is always positive so in case of reducing short in buy, we have to subtract
    attr(o, :committed)[] -= t.amount # from pos to 0 (sell amount is neg)
    @deassert committed(o) >= 0
end

amount(o::Order) = getfield(o, :amount)
committed(o::LimitOrder) = begin
    @deassert attr(o, :committed)[] >= 0.0
    attr(o, :committed)[]
end
Base.isopen(o::LimitOrder) = o.attrs.unfilled[] ≉ 0.0
isfilled(o::LimitOrder) = o.attrs.unfilled[] ≈ 0.0
islastfill(t::Trade{<:LimitOrderType}) =
    let o = t.order
        t.amount != o.amount && isfilled(o)
    end
isfirstfill(t::Trade{<:LimitOrderType}) =
    let o = t.order
        attr(o, :unfilled)[] == negate(t.amount)
    end
@doc "Check if this is the last trade of the order and if so unqueue it."
fullfill!(s::Strategy, ai, o::LimitOrder, ::Trade) = isfilled(o) && pop!(s, ai, o)

@doc "Add a limit order to the pending orders of the strategy."
function queue!(s::Strategy, o::Order{<:LimitOrderType{S}}, ai) where {S<:OrderSide}
    # This is already done in general by the function that creates the order
    iscommittable(s, o, ai) || return false
    hold!(s, ai, o)
    commit!(s, o, ai)
    push!(s, ai, o)
    return true
end
