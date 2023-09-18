using Lang: @deassert, @lget!, Option, @ifdebug
using OrderTypes: ExchangeID
import OrderTypes: commit!, positionside, LiquidationType, trades
using Strategies: Strategies as st, NoMarginStrategy, MarginStrategy, IsolatedStrategy
using Instances: notional, pnl, Instances
import Instances: committed
using Misc: Short, DFT, toprecision
using Instruments
using Instruments: @importcash!, AbstractAsset
import .Checks: cost
@importcash!
import Base: fill!
import Misc: reset!, attr

##  committed::DFT # committed is `cost + fees` for buying or `amount` for selling
const _BasicOrderState{T} = NamedTuple{
    (:take, :stop, :committed, :unfilled, :trades),
    Tuple{Option{T},Option{T},Ref{T},Ref{T},Vector{Trade}},
}

function basic_order_state(
    take, stop, committed::Ref{T}, unfilled::Ref{T}, trades=Trade[]
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
    loss=nothing,
    profit=nothing,
    id="",
)
    ismonotonic(loss, price, profit) || return nothing
    iscost(ai, amount, loss, price, profit) || return nothing
    @deassert if type <: IncreaseOrder
        committed[] * leverage(ai, positionside(type)) >= ai.limits.cost.min
    else
        abs(committed[]) >= ai.limits.amount.min
    end "Order committment too low\n$(committed[]), $(ai.asset) $date"
    let unfilled = Ref(unfillment(type, amount))
        @deassert type <: AnyBuyOrder ? unfilled[] < 0.0 : unfilled[] > 0.0
        OrderTypes.Order(
            ai,
            type;
            date,
            price,
            amount,
            id,
            attrs=basic_order_state(profit, loss, committed, unfilled),
        )
    end
end

@doc "Remove a single order from the order queue."
function Base.delete!(s::Strategy, ai, o::IncreaseOrder)
    @deassert !(o isa MarketOrder) # Market Orders are never queued
    @deassert committed(o) |> approxzero o
    delete!(orders(s, ai, orderside(o)), pricetime(o))
    @deassert pricetime(o) ∉ keys(orders(s, ai, orderside(o)))
    # If we don't have cash for this asset, it should be released from holdings
    release!(s, ai, o)
end
function Base.delete!(s::Strategy, ai, o::SellOrder)
    @deassert committed(o) |> approxzero o
    delete!(orders(s, ai, orderside(o)), pricetime(o))
    # If we don't have cash for this asset, it should be released from holdings
    release!(s, ai, o)
end
function Base.delete!(s::Strategy, ai, o::ShortBuyOrder)
    # Short buy orders have negative committment
    @deassert committed(o) |> approxzero o
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

@doc "Check if an order is already added to the queue."
function isqueued(o::Order{<:OrderType{S}}, s::Strategy, ai) where {S<:OrderSide}
    let k = pricetime(o), d = orders(s, ai, S)
        k in keys(d)
    end
end

# checks order committment to be within expected values
function _check_committment(o)
    @deassert attr(o, :committed)[] |> gtxzero ||
        ordertype(o) <: MarketOrderType ||
        o isa IncreaseLimitOrder o
end
_check_unfillment(o::AnyLimitOrder{Sell}) = attr(o, :unfilled)[] > 0.0
_check_unfillment(o::AnyLimitOrder{Buy}) = attr(o, :unfilled)[] < 0.0
_check_unfillment(o::AnyMarketOrder{Buy}) = attr(o, :unfilled)[] < 0.0
_check_unfillment(o::AnyMarketOrder{Sell}) = attr(o, :unfilled)[] > 0.0
_check_unfillment(o::LongOrder) = attr(o, :unfilled)[] > 0.0
_check_unfillment(o::ShortOrder) = attr(o, :unfilled)[] < 0.0

# NOTE: unfilled is always negative
function fill!(
    ::Strategy{<:Union{Sim,Paper}}, ai::NoMarginInstance, o::BuyOrder, t::BuyTrade
)
    @deassert o isa IncreaseOrder && _check_unfillment(o) unfilled(o), typeof(o)
    @deassert committed(o) == o.attrs.committed[] && committed(o) >= 0.0
    # from neg to 0 (buy amount is pos)
    attr(o, :unfilled)[] += t.amount
    @deassert attr(o, :unfilled)[] |> ltxzero (o, t.amount)
    # from pos to 0 (buy size is neg)
    attr(o, :committed)[] -= committment(ai, t)
    @deassert gtxzero(ai, committed(o), Val(:price)) || o isa MarketOrder o,
    committment(ai, t)
end
function fill!(
    ::Strategy{<:Union{Sim,Paper}}, ai::AssetInstance, o::SellOrder, t::SellTrade
)
    @deassert o isa SellOrder && _check_unfillment(o)
    @deassert committed(o) == o.attrs.committed[] && committed(o) |> gtxzero
    # from pos to 0 (sell amount is neg)
    attr(o, :unfilled)[] += t.amount
    @deassert attr(o, :unfilled)[] |> gtxzero
    # from pos to 0 (sell amount is neg)
    attr(o, :committed)[] += t.amount
    @deassert committed(o) |> gtxzero
end
function fill!(
    ::Strategy{<:Union{Sim,Paper}}, ai::AssetInstance, o::ShortBuyOrder, t::ShortBuyTrade
)
    @deassert o isa ShortBuyOrder && _check_unfillment(o) o
    @deassert committed(o) == o.attrs.committed[] && committed(o) |> ltxzero
    @deassert attr(o, :unfilled)[] < 0.0
    attr(o, :unfilled)[] += t.amount # from neg to 0 (buy amount is pos)
    @deassert attr(o, :unfilled)[] |> ltxzero
    # NOTE: committment is always positive except for short buy orders
    # where that's committed is shorted (negative) asset cash
    @deassert t.amount > 0.0 && committed(o) < 0.0
    attr(o, :committed)[] += t.amount # from neg to 0 (buy amount is pos)
    @deassert committed(o) |> ltxzero
end

@doc "When entering positions, the cash committed from the trade must be downsized by leverage (at the time of the trade)."
function fill!(
    ::MarginStrategy{<:Union{Sim,Paper}},
    ai::MarginInstance,
    o::IncreaseOrder,
    t::IncreaseTrade,
)
    @deassert o isa IncreaseOrder && _check_unfillment(o) o
    @deassert committed(o) == o.attrs.committed[] && committed(o) > 0.0 t
    attr(o, :unfilled)[] += t.amount
    @deassert attr(o, :unfilled)[] |> ltxzero || o isa ShortSellOrder
    @deassert t.value > 0.0
    attr(o, :committed)[] -= committment(ai, t)
    # Market order spending can exceed the estimated committment
    # ShortSell limit orders can spend more than committed because of slippage
    @deassert committed(o) |> gtxzero || o isa AnyMarketOrder || o isa IncreaseLimitOrder
end

Base.isopen(ai::AssetInstance, o::Order) = !isfilled(ai, o)
@doc "Test if the order amount left to fill is below minimum qty."
Base.iszero(ai::AssetInstance, o::Order) = iszero(ai, unfilled(o))
@doc "True if the order committed value is below minimum quantity."
function Instances.isdust(ai::AssetInstance, o::Order)
    abs(unfilled(o)) * o.price < ai.limits.cost.min
end
isfilled(ai::AssetInstance, o::Order) = isdust(ai, o)

function strategycash!(s::NoMarginStrategy, ai, t::BuyTrade)
    @deassert t.size < 0.0
    add!(s.cash, t.size)
    sub!(s.cash_committed, committment(ai, t))
    @deassert gtxzero(ai, s.cash_committed, Val(:price))
end
function strategycash!(s::NoMarginStrategy, _, t::SellTrade)
    @deassert t.size > 0.0
    add!(s.cash, t.size)
    @deassert s.cash |> gtxzero
end
function strategycash!(s::IsolatedStrategy, ai, t::IncreaseTrade)
    @deassert t.size < 0.0
    # t.amount can be negative for short sells
    margin = t.value / t.leverage
    # subtract realized fees, and added margin
    @deassert t.fees > 0.0 || maxfees(ai) < 0.0
    spent = t.fees + margin
    @deassert spent > 0.0
    sub!(s.cash, spent)
    subzero!(s.cash_committed, committment(ai, t); atol=ai.precision.price)
    @deassert s.cash_committed |> gtxzero s.cash, s.cash_committed.value, orderscount(s)
end
function _showliq(s, unrealized_pnl, gained, po, t)
    get(s.attrs, :verbose, false) || return nothing
    if ordertype(t) <: LiquidationType
        @show positionside(t) s.cash margin(po) t.fees t.leverage t.size price(po) t.order.price t.price liqprice(
            po
        ) unrealized_pnl gained ""
    end
end
_checktrade(t::SellTrade) = @deassert t.amount < 0.0
_checktrade(t::ShortBuyTrade) = @deassert t.amount > 0.0
function strategycash!(s::IsolatedStrategy, ai, t::ReduceTrade)
    @deassert t.size > 0.0
    @deassert abs(cash(ai, positionside(t)())) >= abs(t.amount) (
        cash(ai), t.amount, t.order
    )
    @ifdebug _checktrade(t)
    po = position(ai, positionside(t))
    # The notional tracks current value, but the margin
    # refers to the notional from the (avg) entry price
    # of the position
    margin = abs(t.entryprice * t.amount) / t.leverage
    unrealized_pnl = pnl(po, t.price, t.amount)
    @deassert t.fees > 0.0 || maxfees(ai) < 0.0
    gained = margin + unrealized_pnl - t.fees # minus fees
    @ifdebug _showliq(s, unrealized_pnl, gained, po, t)
    add!(s.cash, gained)
    @deassert s.cash |> gtxzero || (hasorders(s) || hascash(s)) (;
        s.cash, s.cash_committed, t.price, t.amount, unrealized_pnl, t.fees, margin
    )
end

function cash!(s::Strategy, ai, t::Trade)
    @ifdebug _check_trade(t, ai)
    strategycash!(s, ai, t)
    cash!(ai, t)
    @ifdebug _check_cash(ai, positionside(t)())
end

attr(o::Order, sym) = getfield(getfield(o, :attrs), sym)
unfilled(o::Order) = abs(attr(o, :unfilled)[])
filled_amount(o) = abs(o.amount) - unfilled(o)

commit!(s::Strategy, o::IncreaseOrder, _) = begin
    @deassert committed(o) |> gtxzero
    add!(s.cash_committed, committed(o))
end
function commit!(::Strategy, o::ReduceOrder, ai)
    @deassert committed(o) |> ltxzero || positionside(o) == Long
    add!(committed(ai, positionside(o)()), committed(o))
end

function decommit!(s::Strategy, o::IncreaseOrder, ai, cancelled=false)
    @ifdebug _check_committment(o)
    # NOTE: ignore negative values caused by slippage
    @deassert cancelled || isdust(ai, o) o
    sub!(s.cash_committed, committed(o))
    @deassert gtxzero(ai, s.cash_committed, Val(:price)) s.cash_committed.value,
    s.cash.precision,
    o
    attr(o, :committed)[] = 0.0
end
function decommit!(s::Strategy, o::SellOrder, ai, args...)
    # NOTE: ignore negative values caused by slippage
    sub!(committed(ai, Long()), max(0.0, committed(o)))
    @deassert gtxzero(ai, committed(ai, Long()), Val(:amount))
    attr(o, :committed)[] = 0.0
end
function decommit!(s::Strategy, o::ShortBuyOrder, ai, args...)
    @deassert committed(o) |> ltxzero
    sub!(committed(ai, Short()), committed(o))
    attr(o, :committed)[] = 0.0
end
function iscommittable(s::Strategy, o::IncreaseOrder, ai)
    @deassert committed(o) > 0.0
    let c = st.freecash(s), comm = committed(o)
        c >= comm || isapprox(c, comm)
    end
end
function iscommittable(::Strategy, o::SellOrder, ai)
    @deassert committed(o) > 0.0
    let c = Instances.freecash(ai, Long()), comm = committed(o)
        c >= comm || isapprox(c, comm)
    end
end
function iscommittable(::Strategy, o::ShortBuyOrder, ai)
    @deassert committed(o) < 0.0
    let c = Instances.freecash(ai, Short()), comm = committed(o)
        c <= comm || isapprox(c, comm)
    end
end

function hold!(s::Strategy, ai, o::IncreaseOrder)
    @deassert hasorders(s, ai, positionside(o)) || !iszero(ai) o
    push!(s.holdings, ai)
end
hold!(::Strategy, _, ::ReduceOrder) = nothing
function release!(s::Strategy, ai, o::Order)
    iszero(ai) && !hasorders(s, ai, positionside(o)) && delete!(s.holdings, ai)
end
@doc "Cancel an order with given error."
function cancel!(s::Strategy, o::Order, ai; err::OrderError)
    if isqueued(o, s, ai)
        decommit!(s, o, ai, true)
        delete!(s, ai, o)
        st.ping!(s, o, err, ai)
    end
end
@doc "Cleanups to do after a trade (attempt)."
aftertrade!(s, ai, o, _) = aftertrade!(s, ai, o)

amount(o::Order) = getfield(o, :amount)
trades(o::Order) = attr(o, :trades)
function committed(o::ShortBuyOrder{<:AbstractAsset,<:ExchangeID})
    @deassert attr(o, :committed)[] |> ltxzero o
    attr(o, :committed)[]
end
function committed(o::Order)
    @ifdebug _check_committment(o)
    attr(o, :committed)[]
end
cost(o::Order) = o.price * abs(o.amount)

function reset!(o::Order)
    empty!(trades(o))
    attr(o, :committed)[] = committment(ai, o)
    attr(o, :unfilled)[] = unfillment(o)
end
