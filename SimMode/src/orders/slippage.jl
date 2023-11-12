using .Lang: @ifdebug
using .Strategies: MarginStrategy
using Executors: AnyBuyOrder, AnyMarketOrder, AnyLimitOrder
using .Misc: toprecision

spreadopt(::Val{:spread}, date, ai) = sml.spreadat(ai, date, Val(:opcl))
spreadopt(n::T, args...) where {T<:Real} = n
spreadopt(v, args...) = error("`base_slippage` option value not supported ($v)")

function _base_slippage(s::Strategy, date::DateTime, ai)
    spreadopt(s.attrs[:sim_base_slippage], date, ai)
end

_volumeskew(actual_amount, volume) =
    if volume == 0.0
        1.0
    else
        min(1.0, actual_amount / volume)
    end
_priceskew(ai, date) = 1.0 - lowat(ai, date) / highat(ai, date)

_addslippage(::AnyLimitOrder{Buy}, price, slp) = price - slp
_addslippage(::AnyLimitOrder{Sell}, price, slp) = price + slp
_isfavorable(::AnyLimitOrder{Buy}, ai, date) = closeat(ai, date) < openat(ai, date)
_isfavorable(::AnyLimitOrder{Sell}, ai, date) = closeat(ai, date) > openat(ai, date)

@doc "Limit orders can only incur into favorable slippage."
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

function _with_slippage(
    s::Strategy{<:Union{Paper,Sim}}, o::AnyMarketOrder, ai, ::Val{:avg}; date, kwargs...
)
    m = openat(ai, date)
    diff1 = abs(closeat(ai, date - s.timeframe) - openat(ai, date))
    diff2 = abs(closeat(ai, date) - openat(ai, date + s.timeframe))
    slp = (diff1 + diff2) / 2.0
    _addslippage(o, m, slp)
end

_addslippage(::AnyMarketOrder{Buy}, price, slp) = price + slp
_addslippage(::AnyMarketOrder{Sell}, price, slp) = price - slp
@doc "Slippage for market orders is always zero or negative."
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
        o isa Union{LiquidationOrder,ForcedOrder}
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

function _doclamp(::Order{<:LimitOrderType}, price, ai, date)
    clamp(price, lowat(ai, date), highat(ai, date))
end
_doclamp(::Order{<:MarketOrderType}, price, args...) = price
function _do_slippage(s, o, ai; date, price, actual_amount)
    clamp_price = _doclamp(o, price, ai, date)
    @deassert clamp_price > 0.0
    _with_slippage(
        s, o, ai, s.attrs[:sim_market_slippage]; clamp_price, actual_amount, date
    )
end

@doc "Add slippage to given `price` w.r.t. a specific order, date and amount."
function with_slippage(s::Strategy{<:Union{Paper,Sim}}, o, ai; date, price, actual_amount)
    _do_slippage(s, o, ai; date, price, actual_amount)
end
