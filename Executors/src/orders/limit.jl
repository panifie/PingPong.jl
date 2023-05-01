using Instances
using OrderTypes: LimitOrderType
using Strategies: NoMarginStrategy
using Lang: @ifdebug
using Base: negate

function limit_order_state(
    take, stop, committed::Vector{T}, unfilled::Vector{T}, trades=Trade[]
) where {T<:Real}
    _BasicOrderState4{T}((take, stop, committed, unfilled, trades))
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
    OrderTypes.Order(
        ai,
        type;
        date,
        price,
        amount,
        attrs=limit_order_state(take, stop, committed, [negate(committed[])]),
    )
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
Base.fill!(o::LimitOrder{Buy}, t::BuyTrade) = begin
    @deassert o.attrs.unfilled[] <= 0.0
    o.attrs.unfilled[] += t.amount # from neg to pos (buy amount is pos)
    o.attrs.committed[] += t.size # from pos to 0 (buy size is neg)
end
Base.fill!(o::LimitOrder{Sell}, t::SellTrade) = begin
    @deassert o.attrs.unfilled[] <= 0.0
    o.attrs.unfilled[] -= t.amount # from neg to pos (sell amount is neg)
    o.attrs.committed[] += t.amount # from pos to 0 (sell amount is neg)
end

function cash!(s::NoMarginStrategy, ai, t::Trade{<:LimitOrderType{Buy}})
    add!(s.cash, t.size)
    sub!(s.cash_committed, t.size)
    @deassert s.cash >= 0.0 && s.cash_committed >= 0.0
    add!(ai.cash, t.amount)
end
# For isolated strategies cash is already deducted at the time the order is created (before being filled.)
function cash!(_::IsolatedStrategy, ai, t::Trade{<:LimitOrderType{Buy}})
    # FIXME
    @assert !(t isa LongSellTrade)
    add!(ai.cash, t.amount)
end
function cash!(s::NoMarginStrategy, ai, t::Trade{<:LimitOrderType{Sell}})
    add!(s.cash, t.size)
    add!(ai.cash, t.amount)
    add!(ai.cash_committed, t.amount)
    @deassert ai.cash >= 0.0 && ai.cash_committed >= 0.0
end
function cash!(s::IsolatedStrategy, ai, t::Trade{<:LimitOrderType{Sell}})
    add!(s.cash, t.size)
    add!(ai.cash, t.amount)
    add!(ai.cash_committed, t.amount)
end

committed(o::LimitOrder) = o.attrs.committed[]
Base.isopen(o::LimitOrder) = o.attrs.unfilled[] != o.amount
isfilled(o::LimitOrder) = o.attrs.unfilled[] == o.amount
islastfill(o::LimitOrder, t::Trade) = t.amount != o.amount && isfilled(o)
isfirstfill(o::LimitOrder, args...) = o.attrs.unfilled[] == 0.0
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
