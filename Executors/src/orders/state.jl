using .Lang: @deassert, @lget!, Option, @ifdebug
using .OrderTypes: ExchangeID
import .OrderTypes: commit!, positionside, LiquidationType, ReduceOnlyOrder, trades
using Strategies: Strategies as st, NoMarginStrategy, MarginStrategy, IsolatedStrategy
using .Instances: notional, pnl, Instances
import .Instances: committed
using .Misc: Short, DFT, toprecision
using .Instruments
using .Instruments: @importcash!, AbstractAsset
import .Checks: cost
@importcash!
import Base: fill!
import .Misc: reset!, attr

##  committed::DFT # committed is `cost + fees` for buying or `amount` for selling
const _BasicOrderState{T} = NamedTuple{
    (:take, :stop, :committed, :unfilled, :trades),
    Tuple{Option{T},Option{T},Ref{T},Ref{T},Vector{Trade}},
}

@doc """Constructs a basic order state with given parameters.

$(TYPEDSIGNATURES)

"""
function basic_order_state(
    take, stop, committed::Ref{T}, unfilled::Ref{T}, trades=Trade[]
) where {T<:Real}
    _BasicOrderState{T}((take, stop, committed, unfilled, trades))
end

@doc """Constructs an `Order` for a given `OrderType` `type` and inputs.

$(TYPEDSIGNATURES)

"""
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
    if !ismonotonic(loss, price, profit)
        @debug "basic order: prices not monotonic" ai = raw(ai) loss price profit type
        return nothing
    end
    is_reduce_only = type <: ReduceOnlyOrder
    # Allow reduce only orders below minimum cost
    if !iscost(ai, amount, loss, price, profit) && !is_reduce_only
        @debug "basic order: invalid cost" ai = raw(ai) amount loss price profit type
        return nothing
    end
    @deassert if type <: IncreaseOrder
        committed[] * leverage(ai, positionside(type)) >= ai.limits.cost.min
    else
        abs(committed[]) >= ai.limits.amount.min || is_reduce_only
    end "Order committment too low\n$(committed[]), $(ai.asset) $date"
    unfilled = Ref(unfillment(type, amount))
    @deassert type <: AnyBuyOrder ? unfilled[] < ZERO : unfilled[] > ZERO
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

@doc """Removes a single order from the order queue.

$(TYPEDSIGNATURES)

"""
function Base.delete!(s::Strategy, ai, o::IncreaseOrder)
    @deassert !(o isa MarketOrder) # Market Orders are never queued
    @deassert committed(o) |> approxzero o
    delete!(orders(s, ai, orderside(o)), pricetime(o))
    @deassert pricetime(o) ∉ keys(orders(s, ai, orderside(o)))
    # If we don't have cash for this asset, it should be released from holdings
    release!(s, ai)
end

@doc """Removes a single sell order from the order queue.

$(TYPEDSIGNATURES)

"""
function Base.delete!(s::Strategy, ai, o::SellOrder)
    @deassert committed(o) |> approxzero o
    delete!(orders(s, ai, orderside(o)), pricetime(o))
    # If we don't have cash for this asset, it should be released from holdings
    release!(s, ai)
end

@doc """Removes a single short buy order from the order queue.

$(TYPEDSIGNATURES)

"""
function Base.delete!(s::Strategy, ai, o::ShortBuyOrder)
    # Short buy orders have negative committment
    @deassert committed(o) |> approxzero o
    delete!(orders(s, ai, Buy), pricetime(o))
    # If we don't have cash for this asset, it should be released from holdings
    release!(s, ai)
end

@doc """Removes all buy/sell orders for an asset instance.

$(TYPEDSIGNATURES)

"""
function Base.delete!(s::Strategy, ai, t::Type{<:Union{Buy,Sell}})
    delete!.(s, ai, values(orders(s, ai, t)))
end

@doc """Removes all buy and sell orders for an asset instance.

$(TYPEDSIGNATURES)

"""
Base.delete!(s::Strategy, ai, ::Type{BuyOrSell}) = begin
    delete!(s, ai, Buy)
    delete!(s, ai, Sell)
end

@doc """Removes all orders for an asset instance.

$(TYPEDSIGNATURES)

"""
Base.delete!(s::Strategy, ai) = delete!(s, ai, BuyOrSell)

@doc """Inserts an order into the order dict of the asset instance. Orders should be identifiable by a unique (price, date) tuple.

$(TYPEDSIGNATURES)

"""
function Base.push!(s::Strategy, ai, o::Order{<:OrderType{S}}) where {S<:OrderSide}
    let k = pricetime(o), d = orders(s, ai, S) #, stok = searchsortedfirst(d, k)
        @ifdebug if k ∉ keys(d)
            @debug "Duplicate order key" o.id d[k].id o.price o.date
        end
        @assert k ∉ keys(d)
        d[k] = o
    end
end
@doc """Checks if an order is already added to the queue.

$(TYPEDSIGNATURES)

"""
function isqueued(o::Order{<:OrderType{S}}, s::Strategy, ai) where {S<:OrderSide}
    let k = pricetime(o), d = orders(s, ai, S)
        k in keys(d)
    end
end

@doc """Checks order committment to be within expected values.

$(TYPEDSIGNATURES)

"""
function _check_committment(o)
    @deassert attr(o, :committed)[] |> gtxzero ||
              ordertype(o) <: MarketOrderType ||
              o isa IncreaseLimitOrder o
end

@doc """Checks if the unfilled amount for a limit sell order is positive.

$(TYPEDSIGNATURES)

"""
_check_unfillment(o::AnyLimitOrder{Sell}) = attr(o, :unfilled)[] > 0.0

@doc """Checks if the unfilled amount for a limit buy order is negative.

$(TYPEDSIGNATURES)

"""
_check_unfillment(o::AnyLimitOrder{Buy}) = attr(o, :unfilled)[] < 0.0

@doc """Checks if the unfilled amount for a market buy order is negative.

$(TYPEDSIGNATURES)

"""
_check_unfillment(o::AnyMarketOrder{Buy}) = attr(o, :unfilled)[] < 0.0

@doc """Checks if the unfilled amount for a market sell order is positive.

$(TYPEDSIGNATURES)

"""
_check_unfillment(o::AnyMarketOrder{Sell}) = attr(o, :unfilled)[] > 0.0

@doc """Checks if the unfilled amount for a long order is positive.

$(TYPEDSIGNATURES)

"""
_check_unfillment(o::LongOrder) = attr(o, :unfilled)[] > 0.0

@doc """Checks if the unfilled amount for a short order is negative.

$(TYPEDSIGNATURES)

"""
_check_unfillment(o::ShortOrder) = attr(o, :unfilled)[] < 0.0
@doc """Fills a buy order for a no-margin strategy.

$(TYPEDSIGNATURES)

"""
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

@doc """Fills a sell order.

$(TYPEDSIGNATURES)

"""
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

@doc """Fills a short buy order.

$(TYPEDSIGNATURES)

"""
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
@doc """Fills an increase order for a margin strategy.

$(TYPEDSIGNATURES)

"""
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

@doc """Checks if an order is open.

$(TYPEDSIGNATURES)

"""
Base.isopen(ai::AssetInstance, o::Order) = !isfilled(ai, o)

@doc """Checks if the order amount left to fill is below minimum qty.

$(TYPEDSIGNATURES)

"""
Base.iszero(ai::AssetInstance, o::Order) = iszero(ai, unfilled(o))

@doc """Checks if the order committed value is below minimum quantity.

$(TYPEDSIGNATURES)

"""
function Instances.isdust(ai::AssetInstance, o::Order)
    unf = abs(unfilled(o))
    unf < ai.limits.amount.min || unf * o.price < ai.limits.cost.min || unf < ai.limits.amount.min * ai.fees.min
end

function Instances.isdust(ai::AssetInstance, o::ReduceOnlyOrder)
    false
end

@doc """Checks if an order is filled.

$(TYPEDSIGNATURES)

"""
isfilled(ai::AssetInstance, o::Order) =
    isdust(ai, o) || begin
        ot = trades(o)
        if length(ot) > 0
            sum(t.amount for t in trades(o)) >= o.amount
        else
            false
        end
    end

@doc """Updates the strategy's cash after a buy trade.

$(TYPEDSIGNATURES)

"""
function strategycash!(s::NoMarginStrategy, ai, t::BuyTrade)
    @deassert t.size < 0.0
    add!(s.cash, t.size)
    sub!(s.cash_committed, committment(ai, t))
    @deassert gtxzero(ai, s.cash_committed, Val(:price))
end

@doc """Updates the strategy's cash after a sell trade.

$(TYPEDSIGNATURES)

"""
function strategycash!(s::NoMarginStrategy, _, t::SellTrade)
    @deassert t.size > 0.0
    add!(s.cash, t.size)
    @deassert s.cash |> gtxzero
end

@doc """Updates the strategy's cash after an increase trade.

$(TYPEDSIGNATURES)

"""
function strategycash!(s::IsolatedStrategy, ai, t::IncreaseTrade)
    @deassert t.size < 0.0
    # t.amount can be negative for short sells
    margin = t.value / t.leverage
    # subtract realized fees, and added margin
    @deassert t.fees > 0.0 || maxfees(ai) < 0.0
    spent = t.fees + margin
    @deassert spent > 0.0
    sub!(s.cash, spent)
    @ifdebug if committed(s) - committment(ai, t) / committed(s) < 0.0
        @error "cash: trade committment can't be higher that total comm" trade = committment(
            ai, t
        ) total = committed(s)
    end
    subzero!(s.cash_committed, committment(ai, t); atol=ai.limits.cost.min, dothrow=false)
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

@doc """Updates the strategy's cash after a reduce trade.

$(TYPEDSIGNATURES)

"""
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
    @debug "strategycash reduce trade:" gained t.value margin unrealized_pnl t.fees po.entryprice[] cash(
        po
    ) t.price t.leverage t.amount
    add!(s.cash, gained)
    @deassert s.cash |> gtxzero || (hasorders(s) || hascash(s)) (;
        s.cash, s.cash_committed, t.price, t.amount, unrealized_pnl, t.fees, margin
    )
end

@doc """Updates the strategy's and asset instance's cash after a trade.

$(TYPEDSIGNATURES)

"""
function cash!(s::Strategy, ai, t::Trade)
    @ifdebug _check_trade(t, ai)
    strategycash!(s, ai, t)
    cash!(ai, t)
    @ifdebug _check_cash(ai, positionside(t)())
end

@doc """Returns the attribute of an order.

$(TYPEDSIGNATURES)

"""
attr(o::Order, sym) = getfield(getfield(o, :attrs), sym)

@doc """Returns the absolute value of the unfilled amount of an order.

$(TYPEDSIGNATURES)

"""
unfilled(o::Order) = abs(attr(o, :unfilled)[])

@doc """Returns the filled amount of an order.

$(TYPEDSIGNATURES)

"""
filled_amount(o) = abs(o.amount) - unfilled(o)
@doc """Commits an increase order to a strategy.

$(TYPEDSIGNATURES)

"""
function commit!(s::Strategy, o::IncreaseOrder, _)
    @deassert committed(o) |> gtxzero
    add!(s.cash_committed, committed(o))
end

@doc """Commits a reduce order to an asset instance.

$(TYPEDSIGNATURES)

"""
function commit!(::Strategy, o::ReduceOrder, ai)
    @deassert committed(o) |> ltxzero || positionside(o) == Long
    add!(committed(ai, positionside(o)()), committed(o))
end

@doc """Decommits an increase order from a strategy.

$(TYPEDSIGNATURES)

"""
function decommit!(s::Strategy, o::IncreaseOrder, ai, canceled=false)
    @ifdebug _check_committment(o)
    # NOTE: ignore negative values caused by slippage
    @deassert canceled || isdust(ai, o) o
    sub!(s.cash_committed, committed(o))
    @deassert gtxzero(ai, s.cash_committed, Val(:price)) s.cash_committed.value,
    s.cash.precision,
    o
    attr(o, :committed)[] = 0.0
end

@doc """Decommits a sell order from an asset instance.

$(TYPEDSIGNATURES)

"""
function decommit!(s::Strategy, o::SellOrder, ai, args...)
    # NOTE: ignore negative values caused by slippage
    sub!(committed(ai, Long()), max(0.0, committed(o)))
    @deassert gtxzero(ai, committed(ai, Long()), Val(:amount))
    attr(o, :committed)[] = 0.0
end

@doc """Decommits a short buy order from an asset instance.

$(TYPEDSIGNATURES)

"""
function decommit!(s::Strategy, o::ShortBuyOrder, ai, args...)
    @deassert committed(o) |> ltxzero
    sub!(committed(ai, Short()), committed(o))
    attr(o, :committed)[] = 0.0
end
@doc """Checks if an increase order can be committed to a strategy.

$(TYPEDSIGNATURES)

"""
function iscommittable(s::Strategy, o::IncreaseOrder, ai)
    @deassert committed(o) > 0.0
    c = st.freecash(s)
    comm = committed(o)
    c >= comm || isapprox(c, comm)
end

@doc """Checks if a sell order can be committed to an asset instance.

$(TYPEDSIGNATURES)

"""
function iscommittable(::Strategy, o::SellOrder, ai)
    @deassert committed(o) > 0.0
    c = Instances.freecash(ai, Long())
    comm = committed(o)
    c >= comm || isapprox(c, comm)
end

@doc """Checks if a short buy order can be committed to an asset instance.

$(TYPEDSIGNATURES)

"""
function iscommittable(::Strategy, o::ShortBuyOrder, ai)
    @deassert committed(o) < 0.0
    c = Instances.freecash(ai, Short())
    comm = committed(o)
    c <= comm || isapprox(c, comm)
end

@doc """Holds an increase order in a strategy.

$(TYPEDSIGNATURES)

"""
function hold!(s::Strategy, ai, o::IncreaseOrder)
    @deassert hasorders(s, ai, positionside(o)) || !iszero(ai) o
    push!(s.holdings, ai)
end

@doc """Does nothing for a reduce order.

$(TYPEDSIGNATURES)

"""
hold!(::Strategy, _, ::ReduceOrder) = nothing

@doc """Releases an order from a margin strategy.

$(TYPEDSIGNATURES)

"""
function release!(s::Strategy, ai)
    if iszero(ai) && !hasorders(s, ai)
        delete!(s.holdings, ai)
    end
end

@doc """Cancels an order with given error.

$(TYPEDSIGNATURES)

"""
function cancel!(s::Strategy, o::Order, ai; err::OrderError)::Bool
    @debug "Cancelling order" o.id ai = raw(ai) err
    if isqueued(o, s, ai)
        decommit!(s, o, ai, true)
        delete!(s, ai, o)
        st.ping!(s, o, err, ai)
    end
    true
end

@doc """Performs cleanups after a trade (attempt).

$(TYPEDSIGNATURES)

"""
aftertrade!(s, ai, o, t) = aftertrade!(s, ai, o)

@doc """Returns the amount of an order.

$(TYPEDSIGNATURES)

"""
amount(o::Order) = getfield(o, :amount)

@doc """Returns the trades of an order.

$(TYPEDSIGNATURES)

"""
trades(o::Order) = attr(o, :trades)

@doc """Returns the committed amount of a short buy order.

$(TYPEDSIGNATURES)

"""
function committed(o::ShortBuyOrder{<:AbstractAsset,<:ExchangeID})
    @deassert attr(o, :committed)[] |> ltxzero o
    attr(o, :committed)[]
end

@doc """Returns the committed amount of an order.

$(TYPEDSIGNATURES)

"""
function committed(o::Order)
    @ifdebug _check_committment(o)
    attr(o, :committed)[]
end

@doc """Returns the cost of an order.

$(TYPEDSIGNATURES)

"""
cost(o::Order) = o.price * abs(o.amount)

@doc """Resets an order.

$(TYPEDSIGNATURES)

"""
function reset!(o::Order, ai)
    empty!(trades(o))
    attr(o, :committed)[] = committment(ai, o)
    attr(o, :unfilled)[] = unfillment(o)
end

queue!(s::Strategy, o::Order, ai; skipcommit=false) = nothing
