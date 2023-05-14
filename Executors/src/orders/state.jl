using Lang: @deassert, @lget!, Option, @ifdebug
using OrderTypes: ExchangeID
import OrderTypes: commit!, orderpos, LiquidationType
using Strategies: Strategies as st, NoMarginStrategy, MarginStrategy, IsolatedStrategy
using Instances: notional, pnl
import Instances: committed
using Misc: Short, DFT
using Instruments
using Instruments: @importcash!, AbstractAsset
@importcash!
import Base: fill!

##  committed::Float64 # committed is `cost + fees` for buying or `amount` for selling
const _BasicOrderState{T} = NamedTuple{
    (:take, :stop, :committed, :unfilled, :trades),
    Tuple{Option{T},Option{T},Vector{T},Vector{T},Vector{Trade}},
}

function basic_order_state(
    take, stop, committed::Vector{T}, unfilled::Vector{T}, trades=Trade[]
) where {T<:Real}
    _BasicOrderState{T}((take, stop, committed, unfilled, trades))
end

@doc "Construct an `Order` for a given `OrderType` `type` and inputs."
function basicorder(
    ai::AssetInstance,
    price,
    amount,
    committed,
    ::SanitizeOff;
    type::Type{<:Order},
    date,
    take=nothing,
    stop=nothing,
)
    ismonotonic(stop, price, take) || return nothing
    iscost(ai, amount, stop, price, take) || return nothing
    @deassert if type <: IncreaseOrder
        committed[] * leverage(ai, orderpos(type)) >= ai.limits.cost.min
    else
        abs(committed[]) >= ai.limits.amount.min
    end "Order committment too low\n$(committed[]), $(ai.asset) $date"
    let unfilled = unfillment(type, amount)
        @deassert type <: AnyBuyOrder ? unfilled[] < 0.0 : unfilled[] > 0.0
        OrderTypes.Order(
            ai,
            type;
            date,
            price,
            amount,
            attrs=basic_order_state(take, stop, committed, unfilled),
        )
    end
end

@doc "Remove a single order from the order queue."
function Base.delete!(s::Strategy, ai, o::IncreaseOrder)
    @deassert !(o isa MarketOrder) # Market Orders are never queued
    @deassert committed(o) ≈ 0.0 o
    delete!(orders(s, ai, orderside(o)), pricetime(o))
end
function Base.delete!(s::Strategy, ai, o::SellOrder)
    @deassert committed(o) ≈ 0.0 o
    delete!(orders(s, ai, orderside(o)), pricetime(o))
    # If we don't have cash for this asset, it should be released from holdings
    release!(s, ai, o)
end
function Base.delete!(s::Strategy, ai, o::ShortBuyOrder)
    # Short buy orders have negative committment
    @deassert committed(o) ≈ 0.0 o
    @deassert committed(ai, Short()) ≈ 0.0
    delete!(orders(s, ai, Buy), pricetime(o))
    # If we don't have cash for this asset, it should be released from holdings
    release!(s, ai, o)
end
@doc "Remove all buy/sell orders for an asset instance."
function Base.delete!(s::Strategy, ai, t::Type{<:Union{Buy,Sell}})
    delete!.(s, ai, values(orders(s, ai, t)))
end
Base.delete!(s::Strategy, ai, ::Type{Both}) = begin
    delete!(s, ai, Buy)
    delete!(s, ai, Sell)
end
Base.delete!(s::Strategy, ai) = delete!(s, ai, Both)
@doc "Inserts an order into the order dict of the asset instance. Orders should be identifiable by a unique (price, date) tuple."
function Base.push!(s::Strategy, ai, o::Order{<:OrderType{S}}) where {S<:OrderSide}
    let k = pricetime(o), d = orders(s, ai, S) #, stok = searchsortedfirst(d, k)
        @assert k ∉ keys(d) "Orders with same price and date are not allowed."
        d[k] = o
    end
end

# NOTE: unfilled is always negative
function fill!(::NoMarginInstance, o::IncreaseOrder, t::IncreaseTrade)
    @deassert o isa IncreaseOrder && attr(o, :unfilled)[] <= 0.0
    @deassert committed(o) == o.attrs.committed[] && committed(o) >= 0.0
    attr(o, :unfilled)[] += t.amount # from neg to 0 (buy amount is pos)
    @deassert attr(o, :unfilled)[] <= 1e-14
    attr(o, :committed)[] += t.size # from pos to 0 (buy size is neg)
    @deassert committed(o) >= 0.0 || o isa MarketOrder o
end
function fill!(ai::AssetInstance, o::SellOrder, t::SellTrade)
    @deassert o isa SellOrder && attr(o, :unfilled)[] >= 0.0
    @deassert committed(o) == o.attrs.committed[] && committed(o) >= 0.0
    attr(o, :unfilled)[] += t.amount # from pos to 0 (sell amount is neg)
    @deassert attr(o, :unfilled)[] >= -1e-12
    attr(o, :committed)[] += t.amount # from pos to 0 (sell amount is neg)
    @deassert committed(o) >= -1e-12
end
function fill!(::AssetInstance, o::ShortBuyOrder, t::ShortBuyTrade)
    @deassert o isa ShortBuyOrder && attr(o, :unfilled)[] <= 0.0
    @deassert committed(o) == o.attrs.committed[] && committed(o) <= 0.0
    @deassert attr(o, :unfilled)[] < 0.0
    attr(o, :unfilled)[] += t.amount # from pos to 0 (sell amount is neg)
    @deassert attr(o, :unfilled)[] >= 0
    # NOTE: committment is always positive so in case of reducing short in buy, we have to subtract
    attr(o, :committed)[] -= t.amount # from pos to 0 (sell amount is neg)
    @deassert committed(o) <= 0.0
end

@doc "When entering positions, the cash committed from the trade must be downsized by leverage (at the time of the trade)."
function fill!(ai::MarginInstance, o::IncreaseOrder, t::IncreaseTrade)
    @deassert o isa IncreaseOrder && (attr(o, :unfilled)[] <= 0.0 || o isa ShortSellOrder)
    @deassert committed(o) == o.attrs.committed[] && committed(o) >= 0.0
    attr(o, :unfilled)[] += t.amount # from neg to 0 (buy amount is pos)
    @deassert attr(o, :unfilled)[] <= 1e-14
    attr(o, :committed)[] -= t.value / t.leverage + t.fees # from pos to 0 (buy size is neg)
    # Market order spending can exceed the estimated committment
    @deassert committed(o) >= -1e-14 || o isa MarketOrder
end

isfilled(ai::AssetInstance, o::Order) = iszero(ai, attr(o, :unfilled)[])
Base.isopen(ai::AssetInstance, o::Order) = !isfilled(ai, o)

using Instruments: addzero!
function strategycash!(s::NoMarginStrategy{Sim}, _, t::BuyTrade)
    @deassert t.size < 0.0
    add!(s.cash, t.size)
    addzero!(s.cash_committed, t.size)
end
strategycash!(s::NoMarginStrategy{Sim}, _, t::SellTrade) = begin
    @deassert t.size > 0.0
    add!(s.cash, t.size)
end
function strategycash!(s::IsolatedStrategy{Sim}, ai, t::IncreaseTrade)
    @deassert t.size < 0.0
    # t.amount can be negative for short sells
    margin = t.value / t.leverage
    # subtract realized fees, and added margin
    @deassert t.fees > 0.0 || maxfees(ai) < 0.0
    spent = t.fees + margin
    @deassert spent > 0.0
    sub!(s.cash, spent)
    @deassert s.cash >= 0.0
    subzero!(s.cash_committed, spent)
end
function _showliq(s, realized_pnl, gained, po, t)
    get(s.attrs, :verbose, false) || return nothing
    if ordertype(t) <: LiquidationType
        @show orderpos(t) s.cash margin t.leverage t.size price(po) t.order.price t.price liqprice(
            po
        ) realized_pnl gained ""
    end
end
_checktrade(t::SellTrade) = @deassert t.amount < 0.0
_checktrade(t::ShortBuyTrade) = @deassert t.amount > 0.0
function strategycash!(s::IsolatedStrategy{Sim}, ai, t::ReduceTrade)
    @deassert t.size > 0.0
    @deassert abs(cash(ai, orderpos(t)())) >= abs(t.amount)
    @ifdebug _checktrade(t)
    po = position(ai, orderpos(t))
    # The notional tracks current value, but the margin
    # refers to the notional from the (avg) entry price
    # of the position
    margin = abs(price(po) * t.amount) / t.leverage
    unrealized_pnl = pnl(po, t.price, t.amount)
    @deassert t.fees > 0.0 || maxfees(ai) < 0.0
    gained = margin + unrealized_pnl - t.fees # minus fees
    @ifdebug _showliq(s, unrealized_pnl, gained, po, t)
    addzero!(s.cash, gained)
    @deassert s.cash >= 0.0 s.cash
end

function cash!(s::Strategy, ai, t::Trade)
    @ifdebug _check_trade(t)
    strategycash!(s, ai, t)
    cash!(ai, t)
    @ifdebug _check_cash(ai, orderpos(t)())
end

attr(o::Order, sym) = getfield(getfield(o, :attrs), sym)
unfilled(o::Order) = abs(attr(o, :unfilled)[])

commit!(s::Strategy, o::IncreaseOrder, _) = begin
    @deassert committed(o) >= 0.0
    add!(s.cash_committed, committed(o))
end
function commit!(::Strategy, o::ReduceOrder, ai)
    @deassert committed(o) <= 0.0 || orderpos(o) == Long
    add!(committed(ai, orderpos(o)()), committed(o))
end
decommit!(s::Strategy, o::IncreaseOrder, ai) = begin
    @deassert committed(o) >= -1e-14 || ordertype(o) <: MarketOrderType o
    subzero!(s.cash_committed, committed(o))
    attr(o, :committed)[] = 0.0
end
decommit!(s::Strategy, o::SellOrder, ai) = begin
    @deassert committed(o) >= 0.0
    subzero!(committed(ai, Long()), committed(o))
    attr(o, :committed)[] = 0.0
end
function decommit!(s::Strategy, o::ShortBuyOrder, ai)
    @deassert committed(o) <= 0.0
    addzero!(committed(ai, Short()), committed(o))
    attr(o, :committed)[] = 0.0
end
iscommittable(s::Strategy, o::IncreaseOrder, _) = begin
    @deassert committed(o) > 0.0
    st.freecash(s) >= committed(o)
end
function iscommittable(::Strategy, o::SellOrder, ai)
    @deassert committed(o) > 0.0
    Instances.freecash(ai, Long()) >= committed(o)
end
function iscommittable(::Strategy, o::ShortBuyOrder, ai)
    @deassert committed(o) < 0.0
    Instances.freecash(ai, Short()) <= committed(o)
end

hold!(s::Strategy, ai, ::IncreaseOrder) = push!(s.holdings, ai)
hold!(::Strategy, _, ::ReduceOrder) = nothing
release!(::Strategy, _, ::IncreaseOrder) = nothing
function release!(s::Strategy, ai, o::ReduceOrder)
    iszero(ai) && pop!(s.holdings, ai)
end
@doc "Cancel an order with given error."
function cancel!(s::Strategy, o::Order, ai; err::OrderError)
    decommit!(s, o, ai)
    delete!(s, ai, o)
    st.ping!(s, o, err, ai)
end

amount(o::Order) = getfield(o, :amount)
function committed(o::ShortBuyOrder{<:AbstractAsset,<:ExchangeID})
    @deassert attr(o, :committed)[] <= 1e-12 o
    attr(o, :committed)[]
end
committed(o::Order) = begin
    @deassert attr(o, :committed)[] >= -1e-12 || ordertype(o) <: MarketOrderType o
    attr(o, :committed)[]
end
