using ExchangeTypes
import ExchangeTypes: exchangeid
using Instruments
using Instruments: Misc
import Base: ==

using .Misc: config, PositionSide, Long, Short, TimeTicks, Lang
using .Misc.DocStringExtensions
import .Misc: opposite
using .TimeTicks
using .ExchangeTypes: Exchange

@doc """ Abstract type representing an event in an exchange
Types implementing an `ExchangeEvent` must have a `tag::Symbol` field.
Every instance of such event should have a unique tag and an optional group.
"""
abstract type ExchangeEvent{E} end

function event!(
    exc::Exchange,
    kind::Type{<:ExchangeEvent},
    tag,
    group;
    event_date=now(),
    this_date=now(),
    kwargs...,
)
    ev = kind{exc.id}(Symbol(tag), Symbol(group), NamedTuple(k => v for (k, v) in kwargs))
    push!(exc._trace, ev; event_date, this_date)
end

function event!(exc::Exchange, ev::ExchangeEvent; event_date=now(), this_date=now())
    push!(exc._trace, ev; event_date, this_date)
end

@doc """Records an event in the exchange's trace. """
event!(v, args...; kwargs...) = event!(exchange(v), args...; kwargs...)

struct AssetEvent{E} <: ExchangeEvent{E}
    tag::Symbol
    group::Symbol
    data::NamedTuple
end
struct StrategyEvent{E} <: ExchangeEvent{E}
    tag::Symbol
    group::Symbol
    data::NamedTuple
end

@doc """ Abstract type representing the side of an order """
abstract type OrderSide end
@doc """ Abstract type representing the buy side of an order """
abstract type Buy <: OrderSide end
@doc """ Abstract type representing the sell side of an order """
abstract type Sell <: OrderSide end
@doc """ Abstract type representing both sides of an order """
abstract type BuyOrSell <: OrderSide end

@doc """ Abstract type representing the type of an order """
abstract type OrderType{S<:OrderSide} end
@doc """ Abstract type representing any limit order """
abstract type LimitOrderType{S} <: OrderType{S} end
@doc """ Abstract type representing any immediate order """
abstract type ImmediateOrderType{S} <: LimitOrderType{S} end
@doc """ Abstract type representing GTC (good till cancel) orders """
abstract type GTCOrderType{S} <: LimitOrderType{S} end
@doc """ Abstract type representing post only orders"""
abstract type PostOnlyOrderType{S} <: GTCOrderType{S} end
@doc """ Abstract type representing FOK (fill or kill) orders """
abstract type FOKOrderType{S} <: ImmediateOrderType{S} end
@doc """ Abstract type representing IOC (immediate or cancel) orders """
abstract type IOCOrderType{S} <: ImmediateOrderType{S} end
@doc """ Abstract type representing market orders """
abstract type MarketOrderType{S} <: OrderType{S} end
@doc """ Abstract type representing liquidation orders """
abstract type LiquidationType{S} <: MarketOrderType{S} end
@doc """ Abstract type representing forced orders """
abstract type ForcedOrderType{S} <: MarketOrderType{S} end

@doc """An Order is a container for trades, tied to an asset and an exchange.
Its execution depends on the order implementation.

$(FIELDS)

`date`: the time at which the strategy requested the order.
    The strategy is assumed to have *knowledge* of the ohlcv data \
    strictly lower than the timeframe adjusted date.
    Example:
    ```julia
    ts = dt"2020-05-24T02:34:00" # the date of the order request
    tf = @infertf ohlcv # get the timeframe (15m)
    start_date = ohlcv.timestamp[begin]
    stop_date = apply(tf, ts) # normalize date to timeframe
    stop_date -= tf.period # scale down by one timeframe step
    # At this point the stop date would be `2020-05-24T02:30:00`
    # which covers the period between ...02:30:00..02:45:00...
    # Therefore the strategy can only have access to data < 02:30:00
    avail_ohlcv = ohlcv[DateRange(start_date, stop_date), :]
    @assert isless(avail_ohlcv.timestamp[end], dt"2020-05-24T02:30:00")
    @assert isequal(avail_ohlcv.timestamp[end] + tf.period, dt"2020-05-24T02:30:00")
    ```
"""
struct Order{
    T<:OrderType{S} where {S<:OrderSide},A<:AbstractAsset,E<:ExchangeID,P<:PositionSide
}
    asset::A
    exc::E
    date::DateTime
    price::Float64
    amount::Float64
    id::String
    tag::String
    attrs::NamedTuple
end

@doc """ Creates an Order object.

$(TYPEDSIGNATURES)

This function constructs an Order object with the given parameters.
The Order object represents a trade order tied to an asset and an exchange.
The execution of the order depends on the order implementation.
The function takes in parameters for the asset, exchange, order type, position side, price, date, amount, attributes, and an optional id.

"""
function Order(
    a::A,
    e::E,
    ::Type{Order{T}},
    ::Type{P}=Long;
    price,
    date,
    amount,
    attrs=(;),
    id="",
    tag="",
    kwargs...,
) where {T<:OrderType,A<:AbstractAsset,E<:ExchangeID,P<:PositionSide}
    Order{T,A,E,P}(a, e, date, price, amount, id, tag, attrs)
end
function Order(
    a, e, ::Type{Order{T,<:AbstractAsset,<:ExchangeID,P}}; kwargs...
) where {T<:OrderType,P<:PositionSide}
    Order(a, e, Order{T}, P; kwargs...)
end
Base.hash(o::Order{T}) where {T} = hash((T, o.asset, o.exc, o.date, o.price, o.amount))
function Base.hash(o::Order{T}, h::UInt) where {T}
    hash((T, o.asset, o.exc, o.date, o.price, o.amount), h)
end
@doc """ Compares two Order objects based on their date.

$(TYPEDSIGNATURES)

This function compares the date of two Order objects and returns `true` if the date of the first Order is less than the date of the second Order. It is used to sort or compare Orders based on their date.

"""
Base.isless(o1::O1, o2::O2) where {O1,O2<:Order} = isless(o1.date, o2.date)
@doc """ Get the fees of an order.

$(TYPEDSIGNATURES)

This function returns the total fees of an order, which is the sum of the fees of all trades associated with the order.
"""
fees(o::Order) =
    let tds = trades(o)
        if isempty(tds)
            nothing
        else
            sum(fees(t) for t in tds)
        end
    end

@doc "An order that increases the size of a position."
const BuyOrder{A,E} = Order{<:OrderType{Buy},A,E,Long}
@doc "An order that decreases the size of a position."
const SellOrder{A,E} = Order{<:OrderType{Sell},A,E,Long}
@doc "A type representing any order that involves buying, regardless of the specific order type or position side"
const AnyBuyOrder{P,A,E} = Order{<:OrderType{Buy},A,E,P}
@doc "A type representing any order that involves selling, regardless of the specific order type or position side"
const AnySellOrder{P,A,E} = Order{<:OrderType{Sell},A,E,P}
@doc "A type representing an order that opens or adds to a 'long' position in a specific asset"
const LongOrder{O,A,E} = Order{O,A,E,Long}
@doc "A type representing an order that opens or adds to a 'short' position in a specific asset"
const ShortOrder{O,A,E} = Order{O,A,E,Short}
@doc "A type representing a buy order that opens or adds to a 'short' position in a specific asset"
const ShortBuyOrder{A,E} = Order{<:OrderType{Buy},A,E,Short}
@doc "A type representing a sell order that opens or adds to a 'short' position in a specific asset"
const ShortSellOrder{A,E} = Order{<:OrderType{Sell},A,E,Short}
@doc "A type representing any immediate order, regardless of the specific asset, exchange, or position side"
const AnyImmediateOrder{A,E,P} = Order{<:ImmediateOrderType,A,E,P}

@doc "An order that increases the size of a position."
const IncreaseOrder{A,E} = Union{BuyOrder{A,E},ShortSellOrder{A,E}}
@doc "An order that decreases the size of a position."
const ReduceOrder{A,E} = Union{SellOrder{A,E},ShortBuyOrder{A,E}}
@doc "A Market Order type that liquidates a position."
const LiquidationOrder{S,P,A<:AbstractAsset,E<:ExchangeID} = Order{LiquidationType{S},A,E,P}
@doc "A Market Order type called when manually closing a position (to sell the holdings)."
const LongReduceOnlyOrder{A<:AbstractAsset,E<:ExchangeID} = Order{
    ForcedOrderType{Sell},A,E,Long
}
const ShortReduceOnlyOrder{A<:AbstractAsset,E<:ExchangeID} = Order{
    ForcedOrderType{Buy},A,E,Short
}
const ReduceOnlyOrder = Union{LongReduceOnlyOrder,ShortReduceOnlyOrder}

@doc """ Defines various order types in the trading system

$(TYPEDSIGNATURES)

This macro is used to define various order types in the trading system. It takes a boolean value to determine if the order type is a super type, and a list of types to be defined.

"""
macro deforders(issuper, types...)
    @assert issuper isa Bool
    out = quote end
    for t in types
        type_str = string(t)
        order_type_str = type_str * "Order"
        type_sym = Symbol(order_type_str)
        short_type_sym = Symbol("Short" * order_type_str)
        # HACK: const/types definitions inside macros can't be revised
        isdefined(@__MODULE__, type_sym) && continue
        type = esc(type_sym)
        short_type = esc(short_type_sym)
        ordertype = esc(Symbol(type_str * "OrderType"))
        _orderexpr(pos_side) =
            if issuper
                :(Order{<:$ordertype{S},A,E,$pos_side})
            else
                :(Order{$ordertype{S},A,E,$pos_side})
            end
        long_orderexpr = _orderexpr(Long)
        short_orderexpr = _orderexpr(Short)
        push!(
            out.args,
            quote
                const $type{S<:OrderSide,A<:AbstractAsset,E<:ExchangeID} = $long_orderexpr
                const $short_type{S<:OrderSide,A<:AbstractAsset,E<:ExchangeID} =
                    $short_orderexpr
                export $type, $short_type
            end,
        )
    end
    out
end
@deforders false GTC PostOnly FOK IOC Market
@deforders true Limit

==(v1::Type{<:OrderSide}, v2::Type{BuyOrSell}) = true
==(v1::Type{BuyOrSell}, v2::Type{<:OrderSide}) = true
@doc """Get the `OrderType` of an order """
ordertype(::Order{T}) where {T<:OrderType} = T
ordertype(::Type{<:Order{T}}) where {T<:OrderType} = T
@doc """Get the `PositionSide` of an order """
function positionside(
    ::Union{Type{O},O}
) where {O<:Order{T,<:AbstractAsset,<:ExchangeID,P}} where {T,P}
    P
end
positionside(::Union{P,Type{P}}) where {P<:PositionSide} = P
@doc """Get the price and time of an order """
pricetime(o::Order) = (price=o.price, time=o.date)
@doc """Get the `ExchangeID` of an order """
exchangeid(::Order{<:OrderType,<:AbstractAsset,E}) where {E<:ExchangeID} = E
commit!(args...; kwargs...) = error("not implemented")
@doc """Get the opposite side of an order """
opposite(::Type{Buy}) = Sell
opposite(::Type{Sell}) = Buy
function opposite(::Type{T}) where {S,T<:OrderType{S}}
    getfield(T.name.module, T.name.name){opposite(S)}
end
@doc """Get the liquidation side of an order """
liqside(::Union{Long,Type{Long}}) = Sell
liqside(::Union{Short,Type{Short}}) = Buy
@doc """Is the order a liquidation order"""
isliquidation(::Order{O}) where {O<:OrderType} = O == LiquidationType
sidetopos(::Order{<:OrderType{Buy}}) = Long
sidetopos(::Order{<:OrderType{Sell}}) = Short
@doc """Test if an order is a long order"""
islong(p::Union{<:T,<:Type{<:T}}) where {T<:PositionSide} = p == Long()
@doc """Test if an order is a short order"""
isshort(p::Union{<:T,<:Type{<:T}}) where {T<:PositionSide} = p == Short()
islong(o::Union{<:LongOrder,<:Type{<:LongOrder}}) = true
islong(o::Union{<:ShortOrder,<:Type{<:ShortOrder}}) = false
isshort(o::Union{<:LongOrder,<:Type{<:LongOrder}}) = false
isshort(o::Union{<:ShortOrder,<:Type{<:ShortOrder}}) = true
islong(::Nothing) = false
isshort(::Nothing) = false
@doc """Test if an order is an immediate order"""
isimmediate(::Order{<:Union{ImmediateOrderType,MarketOrderType}}) = true
isimmediate(::Order) = false
@doc """Test if the order position side matches the given position side"""
ispos(pos::PositionSide, o::Order) = positionside(o)() == pos
order!(args...; kwargs...) = error("not implemented")
@doc """Get the trades history of an order """
trades(args...; kwargs...) = error("not implemented")

include("trades.jl")
include("positions.jl")
include("balance.jl")
include("ohlcv.jl")
include("errors.jl")
include("print.jl")

@doc "Dispatch by `OrderSide` or by an `Order` or `Trade` with the same side as parameter."
const BySide{S<:OrderSide} = Union{
    S,Type{S},Order{<:OrderType{S}},Type{<:Order{<:OrderType{S}}},Trade{<:OrderType{S}}
}
@doc "A type representing any order with a specific position side"
const AnyOrderPos{P<:PositionSide} =
    Union{O,Type{O}} where {O<:Order{<:OrderType,<:AbstractAsset,<:ExchangeID,P}}
@doc "A type representing any trade with a specific position side"
const AnyTradePos{P<:PositionSide} =
    Union{T,Type{T}} where {T<:Trade{<:OrderType,<:AbstractAsset,<:ExchangeID,P}}
@doc "Dispatch by `PositionSide` or by an `Order` or `Trade` with the same position side as parameter."
const ByPos{P<:PositionSide} = Union{P,Type{P},AnyOrderPos{P},AnyTradePos{P}}

# NOTE: Implementing this function for `ByPos` breaks backtesting, don't do it!
orderside(::BySide{S}) where {S<:OrderSide} = S
isside(what::ByPos{Long}, side::ByPos{Long}) = true
isside(what::ByPos{Short}, side::ByPos{Short}) = true
@doc "Test if the order side matches the given side"
isside(args...) = false
@doc """`Buy` as `Long` and `Sell` as `Short`"""
sidetopos(::BySide{Buy}) = Long()
sidetopos(::BySide{Sell}) = Short()
postoside(::ByPos{Long}) = Buy
postoside(::ByPos{Short}) = Sell

ReduceOnlyOrder(::ByPos{Long}) = LongReduceOnlyOrder
ReduceOnlyOrder(::ByPos{Long}, A) = LongReduceOnlyOrder{A}
ReduceOnlyOrder(::ByPos{Long}, A, E) = LongReduceOnlyOrder{A,E}
ReduceOnlyOrder(::ByPos{Short}) = ShortReduceOnlyOrder
ReduceOnlyOrder(::ByPos{Short}, A) = ShortReduceOnlyOrder{A}
ReduceOnlyOrder(::ByPos{Short}, A, E) = ShortReduceOnlyOrder{A,E}

export Order, OrderType, OrderSide, BySide, Buy, Sell, BuyOrSell, Trade, ByPos
export BuyOrder, SellOrder, BuyTrade, SellTrade, AnyBuyOrder, AnySellOrder
export ShortBuyTrade, ShortSellTrade
export LongOrder, ShortOrder, ShortBuyOrder, ShortSellOrder
export IncreaseOrder, ReduceOrder, IncreaseTrade, ReduceTrade, AnyImmediateOrder
export LiquidationOrder, ReduceOnlyOrder
export OrderError, NotEnoughCash, NotFilled, NotMatched, OrderTimeOut
export OrderFailed, OrderCanceled, LiquidationOverride
export orderside, positionside, pricetime, islong, isshort, ispos, isimmediate, isside
export liqside, sidetopos, opposite
export event!,
    ExchangeEvent,
    AssetEvent,
    StrategyEvent,
    PositionEvent,
    PositionUpdated,
    MarginUpdated,
    LeverageUpdated,
    BalanceUpdated,
    OHLCVUpdated
export fees
