using .Lang: @deassert, @posassert, Lang, @ifdebug
using OrderTypes
using Executors.Checks: cost, withfees
using Executors: AnyFOKOrder, AnyIOCOrder, AnyGTCOrder
import Executors: priceat, unfilled, isqueued
import OrderTypes: order!, FOKOrderType, IOCOrderType
using Simulations: Simulations as sim
using Strategies: Strategies as st

function create_sim_limit_order(s, t, ai; amount, kwargs...)
    o = limitorder(s, ai, amount; type=t, kwargs...)
    isnothing(o) && return nothing
    queue!(s, o, ai) || return nothing
    @deassert abs(committed(o)) > 0.0
    return o
end

@doc "The price at a particular date for an order.
- `datefunc`: the function to normalize the date which takes the timeframe and the date as inputs (default `available`)."
function priceat(s::Strategy{Sim}, ::Type{<:Order}, ai, date; datefunc=available)
    st.closeat(ai, datefunc(s.timeframe, date))
end
priceat(s::Strategy{Sim}, ::T, args...) where {T<:Order} = priceat(s, T, args...)
function priceat(s::MarginStrategy{Sim}, ::T, args...) where {T<:Order}
    priceat(s, T, args...)
end

_istriggered(o::AnyLimitOrder{Buy}, date, ai) = begin
    pbs = _pricebyside(o, date, ai)
    pbs, (pbs <= o.price)
end
_istriggered(o::AnyLimitOrder{Sell}, date, ai) = begin
    pbs = _pricebyside(o, date, ai)
    pbs, pbs >= o.price
end

@doc "Progresses a simulated limit order."
function order!(
    s::NoMarginStrategy{Sim}, o::Order{<:LimitOrderType}, date::DateTime, ai; kwargs...
)
    @deassert abs(committed(o)) > 0.0 o
    limitorder_ifprice!(s, o, date, ai)
end

@doc "Progresses a simulated limit order for an isolated margin strategy."
function order!(
    s::IsolatedStrategy{Sim}, o::Order{<:LimitOrderType}, date::DateTime, ai; kwargs...
)
    @deassert abs(committed(o)) > 0.0 (pricetime(o), o)
    t = limitorder_ifprice!(s, o, date, ai)
    t isa Trade && position!(s, ai, t)
    @deassert s.cash_committed |> gtxzero s.cash_committed.value
    t
end

@doc "Executes a limit order at a particular time only if price is lower(buy) than order price."
function limitorder_ifprice!(s::Strategy{Sim}, o::AnyLimitOrder, date, ai)
    @ifdebug PRICE_CHECKS[] += 1
    pbs, triggered = _istriggered(o, date, ai)
    if triggered
        # Order might trigger on high/low, but execution uses the *close* price.
        limitorder_ifvol!(s, o, date, ai)
    elseif o isa Union{AnyFOKOrder,AnyIOCOrder}
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
function limitorder_ifvol!(s::Strategy{Sim}, o::AnyLimitOrder, date, ai)
    @ifdebug VOL_CHECKS[] += 1
    ans = missing
    cdl_vol = st.volumeat(ai, date)
    amount = unfilled(o)
    @deassert amount > 0.0
    if o isa AnyFOKOrder # check for full fill
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
        @deassert !isqueued(o, s, ai)
    else
        # GTC and IOC can be partially filled so allow for amount reduction (max_depth=4)
        triggered, actual_amount = _fill_happened(
            amount, cdl_vol; max_depth=4, max_reduction=0.1
        )
        if triggered
            @deassert actual_amount > amount * 0.1
            ans = trade!(s, o, ai; price=o.price, date, actual_amount)
        else
            # Cancel IOC orders if partially filled
            o isa AnyIOCOrder &&
                !isfilled(ai, o) &&
                cancel!(s, o, ai; err=NotFilled(amount, cdl_vol))
        end
        @deassert o isa AnyGTCOrder || !isqueued(o, s, ai)
    end
    ans
end
