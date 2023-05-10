using OrderTypes: MarketOrderType, ExchangeID, PositionSide, PositionTrade
using Base: negate

const AnyMarketOrder{S<:OrderSide,P<:PositionSide} = Order{
    <:MarketOrderType{S},<:AbstractAsset,<:ExchangeID,P
}

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
    type,
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
    s::Strategy, ai, amount; date, type, take=nothing, stop=nothing, price, kwargs...
)
    @price! ai take stop
    @amount! ai amount
    comm = committment(type, ai, price, amount)
    if iscommittable(s, type, comm, ai)
        marketorder(ai, price, amount, comm, SanitizeOff(); date, type, kwargs...)
    end
end

function cash!(
    s::NoMarginStrategy, ai, t::PositionTrade{P}{<:MarketOrderType{Buy}}
) where {P<:PositionSide}
    @deassert t.size < 0.0
    @deassert t.amount > 0.0
    add!(s.cash, t.size)
    @deassert s.cash >= 0.0
    add!(ai.cash, t.amount)
end
function cash!(
    s::NoMarginStrategy, ai, t::PositionTrade{P}{<:MarketOrderType{Sell}}
) where {P<:PositionSide}
    @deassert t.size > 0.0
    @deassert t.amount < 0.0
    add!(s.cash, t.size)
    add!(ai.cash, t.amount)
    @deassert ai.cash >= 0.0
end

const LongMarketBuyTrade = Trade{<:MarketOrderType{Buy},<:AbstractAsset,<:ExchangeID,Long}
const LongMarketSellTrade = Trade{<:MarketOrderType{Sell},<:AbstractAsset,<:ExchangeID,Long}

Base.fill!(o::AnyMarketOrder{Buy}, t::BuyTrade) = begin
    @deassert o.attrs.unfilled[] <= 0.0
    o.attrs.unfilled[] += t.amount
end
Base.fill!(o::AnyMarketOrder{Sell}, t::SellTrade) = begin
    @deassert o.attrs.unfilled[] <= 0.0
    o.attrs.unfilled[] -= t.amount
end

@doc "Market reduce orders don't commit asset cash."
function Instruments.cash!(
    ai::MarginInstance, t::Trade{<:MarketOrderType{Sell},A,E,Long}
) where {A,E}
    add!(cash(ai, tradepos(t)()), t.amount)
end
@doc "Market reduce orders don't commit asset cash."
function Instruments.cash!(
    ai::MarginInstance, t::Trade{<:MarketOrderType{Buy},A,E,Short}
) where {A,E}
    add!(cash(ai, tradepos(t)), t.amount)
end

committed(o::MarketOrder) = o.attrs.committed
# FIXME: Should this be ≈/≉?
Base.isopen(o::MarketOrder) = unfilled(o) != 0.0
isfilled(o::MarketOrder) = unfilled(o) == 0.0
islastfill(t::Trade{<:MarketOrderType}) = true
isfirstfill(t::Trade{<:MarketOrderType}) = true
@doc "Does nothing since market orders are never queued."
fullfill!(::Strategy, _, o::AnyMarketOrder, ::Trade) = nothing
