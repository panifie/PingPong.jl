using ExchangeTypes
import ExchangeTypes: exchangeid
using Instruments
using Data: Candle

using Misc: config, PositionSide, Long, Short
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
Base.hash(o::Order{T}) where {T} = hash((T, o.asset, o.exc, o.date, o.price, o.amount))
function Base.hash(o::Order{T}, h::UInt) where {T}
    hash((T, o.asset, o.exc, o.date, o.price, o.amount), h)
end
const BuyOrder{O,A,E,P} =
    Order{O,A,E,P} where {O<:OrderType{Buy},A<:AbstractAsset,E<:ExchangeID,P<:PositionSide}
const SellOrder{O,A,E,P} =
    Order{O,A,E} where {O<:OrderType{Sell},A<:AbstractAsset,E<:ExchangeID,P<:PositionSide}
const LongOrder{O,A,E} = Order{O,A,E,Long}
const ShortOrder{O,A,E} = Order{O,A,E,Short}
const LongBuyOrder{O,A,E} = BuyOrder{O,A,E,Long}
const LongSellOrder{O,A,E} = SellOrder{O,A,E,Long}
const ShortBuyOrder{O,A,E} = BuyOrder{O,A,E,Short}
const ShortSellOrder{O,A,E} = SellOrder{O,A,E,Short}
const OrderOrSide{S} = Union{S,Order{O,A,E,S}} where {O,A,E}

macro deforders(issuper, types...)
    @assert issuper isa Bool
    out = quote end
    for t in types
        type_str = string(t)
        type_sym = Symbol(type_str * "Order")
        # HACK: const/types definitions inside macros can't be revised
        isdefined(@__MODULE__, type_sym) && continue
        type = esc(type_sym)
        ordertype = esc(Symbol(type_str * "OrderType"))
        orderexpr = if issuper
            :(Order{<:$ordertype{S},A,E,P})
        else
            :(Order{$ordertype{S},A,E,P})
        end
        push!(
            out.args,
            quote
                const $type{S,A,E,P} = $orderexpr where {
                    S<:OrderSide,A<:AbstractAsset,E<:ExchangeID,P<:PositionSide
                }
            end,
        )
    end
    out
end
@deforders false GTC FOK IOC Market
@deforders true Limit

const ordersdefault! = Returns(nothing)
orderside(::Order{T}) where {T<:OrderType{S}} where {S} = nameof(S)
ordertype(::Order{T}) where {T} = T
orderpos(::Order{T,A,E,P}) where {T,A,E,P} = P
exchangeid(::Order{<:OrderType,<:AbstractAsset,E}) where {E<:ExchangeID} = E

include("trades.jl")
include("positions.jl")
include("errors.jl")

export Order, OrderType, OrderSide, Buy, Sell
export BuyOrder, SellOrder, Trade, BuyTrade, SellTrade
export LongOrder, ShortOrder, LongBuyorder, LongSellOrder, ShortBuyOrder, ShortSellOrder
export LimitOrder, GTCOrder, IOCOrder, FOKOrder, MarketOrder
export OrderError, NotEnoughCash, NotFilled, NotMatched, OrderTimeOut, OrderFailed
export ordersdefault!, orderside
