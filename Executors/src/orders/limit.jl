using Instances
using OrderTypes: LimitOrderType

function limit_order_state(
    take, stop, committed::Vector{T}, filled=[0.0], trades=Trade[]
) where {T}
    _BasicOrderState2{T}((take, stop, committed, filled, trades))
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
        committed,
        attrs=limit_order_state(take, stop, committed),
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

Base.fill!(o::LimitOrder{Buy}, t::BuyTrade) = begin
    o.attrs.filled[1] += t.amount
    o.attrs.committed[1] -= t.size
end
Base.fill!(o::LimitOrder{Sell}, t::SellTrade) = begin
    o.attrs.filled[1] += t.amount
    o.attrs.committed[1] -= t.amount
end

function cash!(s::Strategy, ai, t::BuyTrade{<:LimitOrderType{Buy}})
    sub!(s.cash, t.size)
    sub!(s.cash_committed, t.size)
    @deassert s.cash >= 0.0 && s.cash_committed >= 0.0
    add!(ai.cash, t.amount)
end
function cash!(s::Strategy, ai, t::SellTrade{<:LimitOrderType{Sell}})
    add!(s.cash, t.size)
    sub!(ai.cash, t.amount)
    sub!(ai.cash_committed, t.amount)
    @deassert ai.cash >= 0.0 && ai.cash_committed >= 0.0
end

committed(o::LimitOrder) = o.attrs.committed[1]
Base.isopen(o::LimitOrder) = o.attrs.filled[1] != o.amount
isfilled(o::LimitOrder) = o.attrs.filled[1] == o.amount
islastfill(o::LimitOrder, t::Trade) = t.amount != o.amount && isfilled(o)
isfirstfill(o::LimitOrder, args...) = o.attrs.filled[1] == 0.0
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
