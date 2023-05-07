using ExchangeTypes
import ExchangeTypes: exchangeid
using Instruments
using Data: Candle

using Misc: config, PositionSide, Long, Short
import Misc: opposite
using TimeTicks
using Lang: Lang

abstract type ExchangeEvent{E} end
abstract type AssetEvent{E} <: ExchangeEvent{E} end
abstract type StrategyEvent{E} <: ExchangeEvent{E} end

abstract type OrderSide end
abstract type Buy <: OrderSide end
abstract type Sell <: OrderSide end
abstract type Both <: OrderSide end

abstract type OrderType{S<:OrderSide} end
abstract type LimitOrderType{S} <: OrderType{S} end
abstract type GTCOrderType{S} <: LimitOrderType{S} end
abstract type FOKOrderType{S} <: LimitOrderType{S} end
abstract type IOCOrderType{S} <: LimitOrderType{S} end
abstract type MarketOrderType{S} <: OrderType{S} end
# struct LadderOrder <: OrderType end
# struct RebalanceOrder <: OrderType end

@doc """An Order is a container for trades, tied to an asset and an exchange.
Its execution depends on the order implementation.

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
} <: AssetEvent{E}
    asset::A
    exc::E
    date::DateTime
    price::Float64
    amount::Float64
    attrs::NamedTuple
end

function Order(
    a::A, e::E, ::Type{Order{T}}, ::Type{P}=Long; price, date, amount, attrs=(;), kwargs...
) where {T<:OrderType,A<:AbstractAsset,E<:ExchangeID,P<:PositionSide}
    Order{T,A,E,P}(a, e, date, price, amount, attrs)
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

const BuyOrder{A,E} = Order{<:OrderType{Buy},A,E,Long}
const SellOrder{A,E} = Order{<:OrderType{Sell},A,E,Long}
const LongOrder{O,A,E} = Order{O,A,E,Long}
const ShortOrder{O,A,E} = Order{O,A,E,Short}
const ShortBuyOrder{A,E} = Order{<:OrderType{Buy},A,E,Short}
const ShortSellOrder{A,E} = Order{<:OrderType{Sell},A,E,Short}

@doc "An order that increases the size of a position."
const IncreaseOrder{A,E} = Union{BuyOrder{A,E},ShortSellOrder{A,E}}
@doc "An order that decreases the size of a position."
const ReduceOrder{A,E} = Union{SellOrder{A,E},ShortBuyOrder{A,E}}
@doc "Dispatch by `OrderSide` or by an `Order` with the same side as parameter."
const OrderOrSide{S} = Union{S,Order{OrderType{S},A,E,S}} where {A,E}

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
@deforders false GTC FOK IOC Market
@deforders true Limit

const ordersdefault! = Returns(nothing)
orderside(::Order{T}) where {T<:OrderType{S}} where {S} = S
ordertype(::Order{T}) where {T} = T
function orderpos(
    ::Union{Type{O},O}
) where {O<:Order{T,<:AbstractAsset,<:ExchangeID,P}} where {T,P}
    P
end
pricetime(o::Order) = (price=o.price, time=o.date)
exchangeid(::Order{<:OrderType,<:AbstractAsset,E}) where {E<:ExchangeID} = E
commit!(args...; kwargs...) = error("not implemented")
opposite(::Buy) = Sell()
opposite(::Type{Buy}) = Sell
opposite(::Sell) = Buy()
opposite(::Type{Sell}) = Buy

include("trades.jl")
include("positions.jl")
include("errors.jl")
include("print.jl")

export Order, OrderType, OrderSide, Buy, Sell, Both, Trade
export BuyOrder, SellOrder, BuyTrade, SellTrade
export ShortBuyTrade, ShortSellTrade
export LongOrder, ShortOrder, ShortBuyOrder, ShortSellOrder
export IncreaseOrder, ReduceOrder, IncreaseTrade, ReduceTrade
export OrderError, NotEnoughCash, NotFilled, NotMatched, OrderTimeOut, OrderFailed
export ordersdefault!, orderside, orderpos, pricetime
