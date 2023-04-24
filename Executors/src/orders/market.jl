using OrderTypes: MarketOrderType
using Misc: MVector

const _MarketOrderState4{T} = NamedTuple{
    (:take, :stop, :committed, :filled, :trades),
    Tuple{Option{T},Option{T},T,MVector{1, T},Vector{Trade}},
}

function market_order_state(
    take, stop, committed::T, filled=MVector(0.0), trades=Trade[]
) where {T}
    _MarketOrderState4{T}((take, stop, committed, filled, trades))
end

function marketorder(
    ai::AssetInstance,
    price,
    amount,
    committed,
    ::SanitizeOff;
    type=MarketOrder{Buy},
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
        attrs=market_order_state(take, stop, committed[1]),
    )
end

function marketorder(
    s::Strategy, ai, amount; date, type, take=nothing, stop=nothing, kwargs...
)
    @price! ai take stop
    @amount! ai amount
    price = priceat(s, type, ai, date)
    comm = committment(type, price, amount, maxfees(ai))
    # @show type iscommittable(s, type, comm, ai) comm ai.cash ai.cash_committed s.cash s.cash_committed
    if iscommittable(s, type, comm, ai)
        marketorder(ai, price, amount, comm, SanitizeOff(); date, type, kwargs...)
    end
end

function cash!(s::Strategy, ai, t::BuyTrade{<:MarketOrderType{Buy}})
    sub!(s.cash, t.size)
    @deassert s.cash >= 0.0
    add!(ai.cash, t.amount)
end
function cash!(s::Strategy, ai, t::SellTrade{<:MarketOrderType{Sell}})
    add!(s.cash, t.size)
    sub!(ai.cash, t.amount)
    @deassert ai.cash >= 0.0
end

Base.fill!(o::MarketOrder{Buy}, t::BuyTrade) = begin
    o.attrs.filled[1] += t.amount
end
Base.fill!(o::MarketOrder{Sell}, t::SellTrade) = begin
    o.attrs.filled[1] += t.amount
end

committed(o::MarketOrder) = o.attrs.committed
filled(o::MarketOrder) = o.attrs.filled[1]
Base.isopen(o::MarketOrder) = o.attrs.filled[1] == 0.0
isfilled(o::MarketOrder) = o.attrs.filled[1] > 0.0
islastfill(o::MarketOrder, t::Trade) = true
isfirstfill(o::MarketOrder, args...) = true
@doc "Does nothing since market orders are never queued."
fullfill!(::Strategy, _, ::MarketOrder, ::Trade) = nothing
