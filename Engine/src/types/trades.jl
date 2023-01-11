module Trades
using Dates
using Lang: @exportenum
using Misc: Candle, convert
using Pairs

@enum BuySignal begin
    Buy
    LadderBuy
    RebalanceBuy
end

@enum SellSignal begin
    Sell
    StopLoss
    TakeProfit
    TrailingStop
    TrailingProfit
    LadderSell
    RebalanceSell
end

@doc "An type to specify the reason why a buy or sell event has happened."
const Signal = Union{BuySignal,SellSignal}

@doc "Buy or Sell? And how much?"
const Order = @NamedTuple{signal::Signal, amount::Float64}

@doc """ A buy or sell event that has happened.
- order: The order received by the strategy
- price: The actual price of execution (accounting for spread)
- amount: The actual amount of the finalized trade (accounting for fees)
"""
struct Trade{T<:Asset}
    pair::T
    order::Order
    candle::Candle
    amount::Float64
    price::Float64
    date::DateTime
    Trade(
        pair::T,
        order::Order,
        candle::Candle,
        amount::Float64,
        price::Float64,
        date::Union{Nothing,DateTime},
    ) where {T<:Asset} = begin
        new{T}(pair, order, candle, amount, price, date)
    end
    Trade(pair::Asset, order, candle) = Trade(
        pair,
        order,
        candle,
        order.amount, # finalized order amount
        candle.close, # finalized price
        candle.timestamp, # date of finalized trade
    )
end

@exportenum BuySignal SellSignal
export Signal, Order, Trade
end
