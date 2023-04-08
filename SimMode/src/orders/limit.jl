using Lang: @deassert
using OrderTypes
using Executors.Checks: cost, withfees
using Simulations: Simulations as sim
using Strategies: Strategies as st

# Pessimistic buy_high/sell_low
# priceat(::Sim, ::Type{<:SellOrder}, ai, date) = st.lowat(ai, date)
# priceat(::Sim, ::Type{<:BuyOrder}, ai, date) = st.highat(ai, date)
function Executors.priceat(s::Strategy{Sim}, ::Type{<:Order}, ai, date)
    st.closeat(ai, available(s.timeframe, date))
end
_addslippage(o::LimitOrder{Buy}, price, slp) = min(o.price, price + slp)
_addslippage(o::LimitOrder{Sell}, price, slp) = max(o.price, price - slp)

function _pricebyslippage(s::Strategy{Sim}, o::Order, ai, price, amount, volume)
    vol_ml = sim.slippage_rate(amount, volume)
    price_ml = sim.slippage_rate(price, o.price)
    ml = vol_ml + price_ml
    bs = _base_slippage(s, o.date, ai)
    slp = bs + bs * ml
    _addslippage(o, price, slp)
end

_pricebyside(::BuyOrder, date, ai) = st.lowat(ai, date)
_pricebyside(::SellOrder, date, ai) = st.highat(ai, date)
_istriggered(o::LimitOrder{Buy}, date, ai) = _pricebyside(o, date, ai) <= o.price
_istriggered(o::LimitOrder{Sell}, date, ai) = _pricebyside(o, date, ai) >= o.price

@doc "Executes a limit order at a particular time only if price is lower(buy) than order price."
function limitorder_ifprice!(s::Strategy{Sim}, o::LimitOrder, date, ai)
    if _istriggered(o, date, ai)
        # Order might trigger on high/low, but execution uses the *close* price.
        limitorder_ifvol!(s, o, st.closeat(ai, date), date, ai)
    elseif o isa Union{FOKOrder,IOCOrder}
        cancel!(s, o, ai; err=NotMatched(o.price, _pricebyside(o, date, ai), 0.0, 0.0))
    else
        missing
    end
end

@doc """
If the buy (sell) price is higher (lower) than current price, starting from
current price we add (remove) slippage. We ensure that price after slippage
adjustement doesn't exceed the *limit* order price.
=== Buy ===
buy_order_price
...
slip_price
...
current_price
...
slip_price
...
sell_order_price
=== Sell ===
"""
function _check_slipprice(slip_price, o::LimitOrder{Buy}, ai, date)
    price = st.lowat(ai, date)
    ((o.price >= price) && (price <= slip_price <= o.price)) ||
        ((o.price < price) && slip_price == o.price)
end

function _check_slipprice(slip_price, o::LimitOrder{Sell}, ai, date)
    price = st.highat(ai, date)
    ((o.price <= price) && (o.price <= slip_price <= price)) ||
        ((o.price > price) && slip_price == o.price)
end

@doc "Executes a limit order at a particular time according to volume (called by `limitorder_ifprice!`)."
function limitorder_ifvol!(s::Strategy{Sim}, o::LimitOrder, price, date, ai)
    cdl_vol = st.volumeat(ai, date)
    amount = o.amount - filled(o)
    if amount < cdl_vol # One trade fills the order completely
        price = _pricebyslippage(s, o, ai, price, amount, cdl_vol)
        @deassert _check_slipprice(price, o, ai, date)
        trade!(s, o, ai; date, price=price, amount)
    elseif cdl_vol > 0.0 && !(o isa FOKOrder)  # Partial fill (Skip partial fills for FOK orders)
        price = _pricebyslippage(s, o, ai, price, amount, cdl_vol)
        @deassert _check_slipprice(price, o, ai, date)
        tr = trade!(s, o, ai; date, price, amount=cdl_vol)
        # Cancel IOC orders after partial fill
        o isa IOCOrder && cancel!(s, o, ai; err=NotFilled(amount, cdl_vol))
        tr
    elseif o isa Union{FOKOrder,IOCOrder}
        cancel!(s, o, ai; err=NotMatched(price, price, amount, cdl_vol))
    else
        missing
    end
end
