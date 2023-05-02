using OrderTypes: MarketOrderType
using Base: negate

const _MarketOrderState4{T} = NamedTuple{
    (:take, :stop, :committed, :unfilled, :trades),
    Tuple{Option{T},Option{T},T,Vector{T},Vector{Trade}},
}

function market_order_state(
    take, stop, committed::T, unfilled::Vector{T}, trades=Trade[]
) where {T}
    _MarketOrderState4{T}((take, stop, committed, unfilled, trades))
end

function marketorder(
    ai::AssetInstance,
    price,
    amount,
    committed,
    ::SanitizeOff;
    type=MarketOrder{Buy,Long},
    date,
    take=nothing,
    stop=nothing,
)
    ismonotonic(stop, price, take) || return nothing
    iscost(ai, amount, stop, price, take) || return nothing
    comm = committed[]
    @deassert comm > 0.0
    # reuse committed vector as _unfilled_
    committed[] = negate(amount)
    let unfilled = committed
        OrderTypes.Order(
            ai,
            type;
            date,
            price,
            amount,
            attrs=market_order_state(take, stop, comm, unfilled),
        )
    end
end

function marketorder(
    s::Strategy, ai, amount; date, type, take=nothing, stop=nothing, kwargs...
)
    @price! ai take stop
    @amount! ai amount
    price = priceat(s, type, ai, date)
    comm = committment(type, price, amount, maxfees(ai))
    if iscommittable(s, type, comm, ai)
        marketorder(ai, price, amount, comm, SanitizeOff(); date, type, kwargs...)
    end
end

function cash!(s::NoMarginStrategy, ai, t::Trade{<:MarketOrderType{Buy}})
    @deassert t.size < 0.0
    @deassert t.amount > 0.0
    add!(s.cash, t.size)
    @deassert s.cash >= 0.0
    add!(ai.cash, t.amount)
end
function cash!(s::NoMarginStrategy, ai, t::Trade{<:MarketOrderType{Sell}})
    @deassert t.size > 0.0
    @deassert t.amount < 0.0
    add!(s.cash, t.size)
    add!(ai.cash, t.amount)
    @deassert ai.cash >= 0.0
end

Base.fill!(o::MarketOrder{Buy}, t::BuyTrade) = begin
    @deassert o.attrs.unfilled[] <= 0.0
    o.attrs.unfilled[] += t.amount
end
Base.fill!(o::MarketOrder{Sell}, t::SellTrade) = begin
    @deassert o.attrs.unfilled[] <= 0.0
    o.attrs.unfilled[] -= t.amount
end

committed(o::MarketOrder) = o.attrs.committed
# FIXME: Should this be ≈/≉?
Base.isopen(o::MarketOrder) = unfilled(o) != 0.0
isfilled(o::MarketOrder) = unfilled(o) == 0.0
islastfill(t::Trade) = true
isfirstfill(t::Trade) = true
@doc "Does nothing since market orders are never queued."
fullfill!(::Strategy, _, o::MarketOrder, ::Trade) = nothing
