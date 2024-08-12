using .Lang: @deassert
using Base: negate
using .Misc: DFT

@doc "The quantity of the base currency being exchanged."
signedamount(amount, ::AnyBuyOrder) = amount
signedamount(amount, ::AnySellOrder) = negate(amount)
@doc "The quantity of the quote currency being exchanged."
signedsize(size, ::IncreaseOrder) = negate(size)
signedsize(size, ::ReduceOrder) = size

# TODO: abstract `Trade` and implement simple trades and richer trades for margin trading
@doc """An order, successfully executed from a strategy request.

$(FIELDS)

Entry trades: The date when the order was actually opened, during backtesting, it is usually `date + tf.period`
    where the timeframe depends on the backtesting `Context`. It should match a candle.
Exit trades: It should match the candle when the buy or sell happened.
"""
struct Trade{O<:OrderType{S} where {S<:OrderSide}, A<:AbstractAsset, E<:ExchangeID, P<:PositionSide}
    "The order that spawned this trade."
    order::Order{O,A,E,P}
    "The date at which the trade (usually its last order) was completed."
    date::DateTime
    "The quantity of the base currency being exchanged + (base)fees.
    NOTE: `amount == value / price - fees_base`, amount should already be (base)fees adjusted.
    Can be negative."
    amount::DFT
    "The actual price (quote currency) of the trade, after slippage."
    price::DFT
    "The value of the trade, calculated as `price * amount`."
    value::DFT
    "The fees paid for the trade.
    NOTE: In live mode, fees are exchange dependent, usually (for spot markets) they are in quote (sells), or base (buys) currency.
    In contracts they are usually in quote or settle currency.
    Some exchanges handle fees with multiple currencies, in those cases only the base/quote currency values are set in the `trade.fees` field,
    while the rest should be tracked through the (live updated) balance.
    Can be negative."
    fees::DFT
    "The fees paid for the trade in the base currency."
    fees_base::DFT
    "The in/out flow of quote currency, calculated as `value +/- (quote)fees`.
    NOTE: `size == value + fees` for `IncreaseTrade` and `size == value - fees` for `ReduceTrade`."
    size::DFT
    "The leverage the trade was executed with."
    leverage::DFT
    "The entry price of the trade."
    entryprice::DFT
    function Trade(
        o::Order{O,A,E,P};
        date,
        amount,
        price,
        fees,
        size,
        lev=1.0,
        entryprice=price,
        fees_base=0.0,
    ) where {O,A,E,P}
        @deassert amount > 0.0
        @deassert size > 0.0
        @deassert abs(amount) <= abs(o.amount)
        amount = signedamount(amount, o)
        value = abs(amount * price)
        @deassert amount == value / price - fees_base
        new{O,A,E,P}(
            o,
            date,
            amount,
            price,
            value,
            fees,
            fees_base,
            signedsize(size, o),
            lev,
            entryprice,
        )
    end
end

@doc "A type representing a trade that opens or adds to a 'long' position in a specific asset"
const LongTrade{O,A,E} = Trade{O,A,E,Long}
@doc "A type representing a trade that opens or adds to a 'short' position in a specific asset"
const ShortTrade{O,A,E} = Trade{O,A,E,Short}
@doc "A type representing a buy trade"
const BuyTrade{A,E} = Trade{<:OrderType{Buy},A,E,Long}
@doc "A type representing a sell trade"
const SellTrade{A,E} = Trade{<:OrderType{Sell},A,E,Long}
@doc "A type representing a short buy trade"
const ShortBuyTrade{A,E} = Trade{<:OrderType{Buy},A,E,Short}
@doc "A type representing a short sell trade"
const ShortSellTrade{A,E} = Trade{<:OrderType{Sell},A,E,Short}
@doc "A type representing an increase trade, which opens or increases the size of a position"
const IncreaseTrade{A,E} = Union{BuyTrade{A,E},ShortSellTrade{A,E}}
@doc "A type representing a reduce trade, which closes or reduces the size of a position"
const ReduceTrade{A,E} = Union{SellTrade{A,E},ShortBuyTrade{A,E}}
@doc "A trade type alias with position as parameter"
const PositionTrade{P} = Trade{O,A,E,P} where {O<:OrderType,A<:AbstractAsset,E<:ExchangeID}
@doc "A type representing a liquidation trade"
const LiquidationTrade{S} = Trade{<:LiquidationType{S}}
@doc "A type representing a long liquidation trade"
const LongLiquidationTrade{S,A,E} = Trade{<:LiquidationType{S},A,E,Long}
@doc "A type representing a short liquidation trade"
const ShortLiquidationTrade{S,A,E} = Trade{<:LiquidationType{S},A,E,Short}

exchangeid(::Trade{<:OrderType,<:AbstractAsset,E}) where {E<:ExchangeID} = E
function positionside(
    ::Trade{<:OrderType,<:AbstractAsset,<:ExchangeID,P}
) where {P<:PositionSide}
    P
end
function orderside(
    ::Trade{<:OrderType{S},<:AbstractAsset,<:ExchangeID,<:PositionSide}
) where {S<:OrderSide}
    S
end
ordertype(::Trade{O}) where {O<:OrderType} = O
islong(o::LongTrade) = true
islong(o::ShortTrade) = false
isshort(o::LongTrade) = false
isshort(o::ShortTrade) = true
@doc "Tests if the trade position side is the given position side"
ispos(pos::PositionSide, t::Trade) = positionside(t) == pos
@doc "Get the fees of a trade."
fees(t::Trade) = getfield(t, :fees) + getfield(t, :fees_base) * getfield(t, :price)