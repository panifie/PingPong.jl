using Instances
using OrderTypes: LimitOrderType
using Strategies: NoMarginStrategy
using Lang: @ifdebug
using Base: negate
using Instruments: addzero!

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
    comm = committment(type, price, amount, maxfees(ai))
    if iscommittable(s, type, comm, ai)
        limitorder(ai, price, amount, comm, SanitizeOff(); date, type, kwargs...)
    end
end

# NOTE: filled is always negative
function Base.fill!(o::LimitOrder{Buy}, t::BuyTrade)
    @deassert o isa BuyOrder && attr(o, :unfilled)[] <= 0.0
    @deassert committed(o) == o.attrs.committed[] && committed(o) >= 0.0
    @deassert t.amount > 0.0
    attr(o, :unfilled)[] += t.amount # from neg to 0 (buy amount is pos)
    @deassert attr(o, :unfilled)[] <= 0
    @deassert t.size < 0.0
    attr(o, :committed)[] += t.size # from pos to 0 (buy size is neg)
    @deassert committed(o) >= 0
end
function Base.fill!(o::LimitOrder{Sell}, t::SellTrade)
    @deassert o isa SellOrder && attr(o, :unfilled)[] >= 0.0
    @deassert committed(o) == o.attrs.committed[] && committed(o) >= 0.0
    attr(o, :unfilled)[] += t.amount # from pos to 0 (sell amount is neg)
    @deassert attr(o, :unfilled)[] >= 0
    attr(o, :committed)[] += t.amount # from pos to 0 (sell amount is neg)
    @deassert committed(o) >= 0
end

function cash!(s::NoMarginStrategy, ai, t::Trade{<:LimitOrderType{Buy}})
    @deassert t.price <= t.order.price
    @deassert t.size < 0.001
    @deassert t.amount > 0.0
    @deassert committed(t.order) >= 0
    add!(s.cash, t.size)
    addzero!(s.cash_committed, t.size)
    @deassert s.cash >= 0.0
    @deassert s.cash_committed >= 0.0
    add!(ai.cash, t.amount)
end
# For isolated strategies cash is already deducted at the time the order is created (before being filled.)
# function cash!(_::IsolatedStrategy, ai, t::Trade{<:LimitOrderType{Buy}})
#     # FIXME
#     @assert !(t isa LongSellTrade)
#     add!(ai.cash, t.amount)
# end
function cash!(s::NoMarginStrategy, ai, t::Trade{<:LimitOrderType{Sell}})
    @deassert t.price >= t.order.price
    @deassert t.size > 0.0
    @deassert t.amount < 0.0
    @deassert committed(t.order) >= 0
    add!(s.cash, t.size)
    add!(ai.cash, t.amount)
    add!(ai.cash_committed, t.amount)
    @deassert ai.cash >= 0.0 && ai.cash_committed >= 0.0
end
# function cash!(s::IsolatedStrategy, ai, t::Trade{<:LimitOrderType{Sell}})
#     add!(s.cash, t.size)
#     add!(ai.cash, t.amount)
#     add!(ai.cash_committed, t.amount)
# end

amount(o::Order) = getfield(o, :amount)
committed(o::LimitOrder) = begin
    @deassert attr(o, :committed)[] >= 0.0
    attr(o, :committed)[]
end
Base.isopen(o::LimitOrder) = o.attrs.unfilled[] != 0.0
isfilled(o::LimitOrder) = o.attrs.unfilled[] == 0.0
islastfill(t::Trade) =
    let o = t.order
        t.amount != o.amount && isfilled(o)
    end
isfirstfill(t::Trade) =
    let o = t.order
        o.attrs.unfilled[] == negate(t.amount)
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
