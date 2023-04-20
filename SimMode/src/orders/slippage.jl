spreadopt(::Val{:spread}, date, ai) = sim.spreadat(ai, date, Val(:opcl))
spreadopt(n::T, args...) where {T<:Real} = n
spreadopt(v, args...) = error("`base_slippage` option value not supported ($v)")

function _base_slippage(s::Strategy, date::DateTime, ai)
    spreadopt(s.attrs[:sim_base_slippage], date, ai)
end

_addslippage(o::LimitOrder{Buy}, slp) = o.price + slp
_addslippage(o::LimitOrder{Sell}, slp) = o.price - slp

function _pricebyslippage(s::Strategy{Sim}, o::Order, ai, trigger_price, amount, volume)
    negative_skew = sim.slippage_rate(amount, volume)
    positive_skew = sim.slippage_rate(trigger_price, o.price)
    # neg skew makes the price _increase_ while pos skew makes it decrease
    skew_rate = 1.0 + negative_skew - positive_skew
    bs = _base_slippage(s, o.date, ai)
    slp = bs * skew_rate
    @deassert slp >= 0.0
    _addslippage(o, slp)
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
