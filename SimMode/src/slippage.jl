using .Lang: @ifdebug
using .Strategies: MarginStrategy
using Executors: AnyBuyOrder, AnyMarketOrder, AnyLimitOrder
using .Misc: toprecision
import Executors: with_slippage

@doc "The default slippage for the strategy."
spreadopt(::Val{:spread}, date, ai) = sml.spreadat(ai, date, Val(:opcl))
@doc "A raw float value (percentage) as slippage."
spreadopt(n::T, args...) where {T<:Real} = n
spreadopt(v, args...) = error("`base_slippage` option value not supported ($v)")

@doc """ Calculate the base slippage for a given strategy, date, and asset.

$(TYPEDSIGNATURES)

This function uses the `spreadopt` function to calculate the base slippage. 
The slippage is determined based on the strategy's attributes, the date, and the asset. 
It is used in the context of trading simulations to model the cost of executing a trade.

"""
_base_slippage
function _base_slippage(s::Strategy, date::DateTime, ai)
    spreadopt(s.attrs[:sim_base_slippage], date, ai)
end

@doc """ Returns a skew factor based on the actual amount and volume.

$(TYPEDSIGNATURES)

This function calculates a skew factor based on the `actual_amount` and `volume`.
If `volume` is 0.0, it returns 1.0.
Otherwise, it returns the minimum between 1.0 and the ratio of `actual_amount` to `volume`.

"""
_volumeskew(actual_amount, volume) =
    if volume == 0.0
        1.0
    else
        min(1.0, actual_amount / volume)
    end
@doc """ Calculates the price skew based on low and high values at a particular date.

$(TYPEDSIGNATURES)

This function finds the skewness of price for a particular asset `ai` at a given `date`.
The skewness is calculated as `1.0 - lowat(ai, date) / highat(ai, date)`.
The function `lowat` and `highat` are used to get the low and high prices respectively.

"""
_priceskew(ai, date) = 1.0 - lowat(ai, date) / highat(ai, date)

@doc "Slippage makes price go down for buy orders."
_addslippage(::AnyLimitOrder{Buy}, price, slp) = price - slp
@doc "Slippage makes price go up for sell orders."
_addslippage(::AnyLimitOrder{Sell}, price, slp) = price + slp
@doc "Buy orders slippage is favorable when the close price is lower than the open price."
_isfavorable(::AnyLimitOrder{Buy}, ai, date) = closeat(ai, date) < openat(ai, date)
@doc "Sell orders slippage is favorable when the close price is higher than the open price."
_isfavorable(::AnyLimitOrder{Sell}, ai, date) = closeat(ai, date) > openat(ai, date)

@doc """ Apply slippage to limit orders based on various factors.

$(TYPEDSIGNATURES)

This function applies slippage to limit orders based on the date of creation, the favorability of the order, price volatility, and volume. 
The slippage is skewed by the difference between price skew and volume skew. 
If the skew rate is negative or zero, there is no slippage. 
Otherwise, the base slippage is calculated and adjusted by the skew rate. 
The final price is clamped within the high and low prices of the asset for the given date.

"""
function _with_slippage(
    s::Strategy{<:Union{Paper,Sim}},
    o::AnyLimitOrder,
    ai,
    ::Val;
    clamp_price,
    actual_amount,
    date,
)
    # slippage on limit orders can only happen on date of creation
    date == o.date || return clamp_price
    # buy/sell orders can have favorable slippage respectively only on red/green candles
    _isfavorable(o, ai, date) || return clamp_price
    # slippage is skewed by price volatility
    price_skew = _priceskew(ai, date)
    # less volume decreases the likelyhood of favorable slippage
    volume = volumeat(ai, date)
    volume_skew = _volumeskew(actual_amount, volume)
    skew_rate = price_skew - volume_skew
    # If skew is negative there is no slippage since limit orders
    # can't have unfavorable slippage
    if skew_rate <= 0.0
        clamp_price
    else
        bs = _base_slippage(s, date, ai)
        slp = bs * (1.0 + skew_rate)
        @deassert slp >= 0.0
        slp_price = _addslippage(o, clamp_price, slp)
        @deassert volume > 0
        volume > 0.0 ? clamp(slp_price, lowat(ai, date), highat(ai, date)) : slp_price
    end
end

@doc """ Apply slippage to market orders based on average price.

$(TYPEDSIGNATURES)

This function calculates the slippage for market orders based on the average price. 
The slippage is calculated as the average of the absolute differences between the open price and the close prices at the previous and next timeframes. 
The final price is then adjusted by the calculated slippage.

"""
function _with_slippage(
    s::Strategy{<:Union{Paper,Sim}}, o::AnyMarketOrder, ai, ::Val{:avg}; date, kwargs...
)
    m = openat(ai, date)
    diff1 = abs(closeat(ai, date - s.timeframe) - openat(ai, date))
    diff2 = abs(closeat(ai, date) - openat(ai, date + s.timeframe))
    slp = (diff1 + diff2) / 2.0
    _addslippage(o, m, slp)
end

@doc "Market buy orders price is increased by slippage."
_addslippage(::AnyMarketOrder{Buy}, price, slp) = price + slp
@doc "Market sell orders price is decreased by slippage."
_addslippage(::AnyMarketOrder{Sell}, price, slp) = price - slp
@doc """ Apply slippage to market orders based on skew.

$(TYPEDSIGNATURES)

This function calculates the slippage for market orders based on the skew. 
The skew is calculated as the sum of the volume skew and the price skew. 
The base slippage is then adjusted by the skew rate. 
The final price is clamped within the high and low prices of the asset for the given date, unless the volume skew is very small.

"""
function _with_slippage(
    s::Strategy{<:Union{Paper,Sim}},
    o::AnyMarketOrder,
    ai,
    ::Val{:skew};
    clamp_price,
    actual_amount,
    date,
)
    @deassert o.price == priceat(s, o, ai, date) ||
        o isa Union{LiquidationOrder,ReduceOnlyOrder}
    volume = volumeat(ai, date)
    volume_skew = _volumeskew(actual_amount, volume)
    price_skew = _priceskew(ai, date)
    # neg skew makes the price _increase_ while pos skew makes it decrease
    skew_rate = volume_skew + price_skew
    bs = _base_slippage(s, o.date, ai)
    slp = if skew_rate <= 0.0
        bs
    else
        bs_skew = clamp_price * skew_rate
        muladd(bs, bs_skew > 10.0 ? log10(bs_skew) : bs_skew / 10.0, bs)
    end
    @assert !isnan(slp)
    @deassert slp >= 0.0
    slp_price = _addslippage(o, clamp_price, slp)
    # We only go outside candle high/low boundaries if the candle
    # has very little volume, otherwise assume that liquidity is deep enough
    if o isa AnyBuyOrder
        @assert slp_price >= clamp_price (slp_price, clamp_price)
    else
        @assert slp_price <= clamp_price (slp_price, clamp_price)
    end
    if volume_skew < 1e-3 && !(o isa LiquidationOrder)
        clamp(slp_price, lowat(ai, date), highat(ai, date))
    else
        slp_price
    end
end

@doc """ Clamp the price within the high and low prices of the asset for the given date.

$(TYPEDSIGNATURES)

This function clamps the price of a limit order within the high and low prices of the asset for the given date.

"""
function _doclamp(::Order{<:LimitOrderType}, price, ai, date)
    clamp(price, lowat(ai, date), highat(ai, date))
end
@doc "Market order price is never clamped."
_doclamp(::Order{<:MarketOrderType}, price, args...) = price
@doc """ Apply slippage to the given price with respect to a specific order, date, and amount.

$(TYPEDSIGNATURES)

This function first clamps the price within the high and low prices of the asset for the given date. 
Then, it applies slippage to the clamped price based on the market slippage attribute of the strategy.

"""
function _do_slippage(s, o, ai; date, price, actual_amount)
    clamp_price = _doclamp(o, price, ai, date)
    @deassert clamp_price > 0.0
    _with_slippage(
        s, o, ai, s.attrs[:sim_market_slippage]; clamp_price, actual_amount, date
    )
end

@doc """ Apply slippage to given `price` with respect to a specific order, date, and amount.

$(TYPEDSIGNATURES)

This function applies slippage to the given price with respect to a specific order, date, and amount. 
It first clamps the price within the high and low prices of the asset for the given date, then applies slippage to the clamped price.

"""
function Executors.with_slippage(s::Strategy{<:Union{Paper,Sim}}, o, ai; date, price, actual_amount)
    _do_slippage(s, o, ai; date, price, actual_amount)
end
