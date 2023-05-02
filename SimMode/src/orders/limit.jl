using Lang: @deassert, @posassert, Lang
using OrderTypes
using Executors.Checks: cost, withfees
import Executors: priceat, unfilled
using Simulations: Simulations as sim
using Strategies: Strategies as st

# Pessimistic buy_high/sell_low
# priceat(::Sim, ::Type{<:SellOrder}, ai, date) = st.lowat(ai, date)
# priceat(::Sim, ::Type{<:BuyOrder}, ai, date) = st.highat(ai, date)
function priceat(s::Strategy{Sim}, ::Type{<:Order}, ai, date)
    st.closeat(ai, available(s.timeframe, date))
end
priceat(s::Strategy{Sim}, o::Order, args...) = priceat(s, typeof(o), args...)

_istriggered(o::LimitOrder{Buy}, date, ai) = begin
    pbs = _pricebyside(o, date, ai)
    pbs, (pbs <= o.price)
end
_istriggered(o::LimitOrder{Sell}, date, ai) = begin
    pbs = _pricebyside(o, date, ai)
    pbs, pbs >= o.price
end

@doc "Executes a limit order at a particular time only if price is lower(buy) than order price."
function limitorder_ifprice!(s::Strategy{Sim}, o::LimitOrder, date, ai)
    pbs, triggered = _istriggered(o, date, ai)
    if triggered
        # Order might trigger on high/low, but execution uses the *close* price.
        limitorder_ifvol!(s, o, date, ai)
    elseif o isa Union{FOKOrder,IOCOrder}
        cancel!(s, o, ai; err=NotMatched(o.price, pbs, 0.0, 0.0))
    else
        missing
    end
end

# The probability the trade should succeed
function _fill_happened(
    amount, cdl_vol, depth=1; initial_amount=amount, max_depth=4, max_reduction=0.1
)
    # The higher the volume of the candle compared to the order amount
    # the more likely the trade will succeed
    Lang.@posassert amount cdl_vol depth initial_amount max_depth max_reduction
    ratio = cdl_vol / amount
    if ratio > 100.0
        true, amount
    elseif ratio > 10.0
        rand() < log10(ratio), amount
    elseif depth < max_depth # Only try a small number of times with reduced amount
        reduced_amount = amount / 2.0
        if reduced_amount > initial_amount * max_reduction
            _fill_happened(reduced_amount, cdl_vol, depth + 1; initial_amount)
        else
            false, 0.0
        end
    else
        false, 0.0
    end
end

@doc "Executes a limit order at a particular time according to volume (called by `limitorder_ifprice!`)."
function limitorder_ifvol!(s::Strategy{Sim}, o::LimitOrder, date, ai)
    ans = missing
    cdl_vol = st.volumeat(ai, date)
    amount = unfilled(o)
    @deassert amount > 0.0
    if o isa FOKOrder # check for full fill
        # FOK can only be filled with max amount, so use max_depth=1
        triggered, actual_amount = _fill_happened(amount, cdl_vol; max_depth=1)
        if triggered
            @deassert amount == actual_amount
            ans = trade!(s, o, ai; price=o.price, date, actual_amount)
        else
            cancel!(
                s, o, ai; err=NotMatched(o.price, priceat(s, o, ai, date), amount, cdl_vol)
            )
        end
    else
        # GTC and IOC can be partially filled so allow for amount reduction (max_depth=4)
        triggered, actual_amount = _fill_happened(
            amount, cdl_vol; max_depth=4, max_reduction=0.1
        )
        if triggered
            @deassert actual_amount > amount * 0.1
            ans = trade!(s, o, ai; price=o.price, date, actual_amount)
        end
        # Cancel IOC orders if partially filled
        o isa IOCOrder && !isfilled(o) && cancel!(s, o, ai; err=NotFilled(amount, cdl_vol))
    end
    ans
end
