using .Lang: @deassert, @posassert, Lang, @ifdebug
using .OrderTypes
using Executors.Checks: cost, withfees
using Executors: AnyFOKOrder, AnyIOCOrder, AnyGTCOrder, AnyPostOnlyOrder
import Executors: priceat, unfilled, isqueued
import .OrderTypes: order!, FOKOrderType, IOCOrderType
using Simulations: Simulations as sml
using .Strategies: Strategies as st

@doc """ Creates a simulated limit order.

$(TYPEDSIGNATURES)

This function creates a limit order in a simulated environment. It takes a strategy `s`, an order type `t`, and an asset `ai` as inputs, along with an `amount` and an optional `skipcommit` flag. If the order is valid, it is queued for execution.
"""
function create_sim_limit_order(s, t, ai; amount, skipcommit=false, kwargs...)
    o = limitorder(s, ai, amount; type=t, skipcommit, kwargs...)
    isnothing(o) && return nothing
    queue!(s, o, ai; skipcommit) || return nothing
    @deassert skipcommit || abs(committed(o)) > 0.0
    return o
end

@doc """ The price at a particular date for an order.

$(TYPEDSIGNATURES)

This function returns the price at a particular date for an order. It takes a strategy `s`, an order type, an asset `ai`, and a date as inputs.
"""
function priceat(s::Strategy{Sim}, ::Type{<:Order}, ai, date)
    st.openat(ai, date)
end
priceat(s::Strategy{Sim}, ::T, args...) where {T<:Order} = priceat(s, T, args...)
function priceat(s::MarginStrategy{Sim}, ::T, args...) where {T<:Order}
    priceat(s, T, args...)
end

@doc """ Determines if a buy limit order is triggered.

$(TYPEDSIGNATURES)

This function checks if a buy limit order `o` is triggered at a given `date` for an asset `ai`. It returns a boolean indicating whether the order is triggered.
"""
_istriggered(o::AnyLimitOrder{Buy}, date, ai) = begin
    pbs = _pricebyside(o, date, ai)
    pbs, (pbs <= o.price)
end
@doc """ Determines if a sell limit order is triggered.

$(TYPEDSIGNATURES)

This function checks if a sell limit order `o` is triggered at a given `date` for an asset `ai`. It returns a boolean indicating whether the order is triggered.
"""
_istriggered(o::AnyLimitOrder{Sell}, date, ai) = begin
    pbs = _pricebyside(o, date, ai)
    pbs, pbs >= o.price
end

@doc "Progresses a simulated limit order."
function order!(
    s::NoMarginStrategy{Sim}, o::Order{<:LimitOrderType}, date::DateTime, ai; kwargs...
)
    @deassert abs(committed(o)) > 0.0 o
    limitorder_ifprice!(s, o, date, ai; kwargs...)
end

@doc "Progresses a simulated limit order for an isolated margin strategy."
function order!(
    s::IsolatedStrategy{Sim}, o::Order{<:LimitOrderType}, date::DateTime, ai; kwargs...
)
    @deassert abs(committed(o)) > 0.0 (pricetime(o), o)
    t = limitorder_ifprice!(s, o, date, ai; kwargs...)
    @deassert gtxzero(s.cash_committed, atol=2s.cash_committed.precision) s.cash_committed.value
    t
end

@doc """ Executes a limit order at a particular time only if price is lower(buy) or higher(sell) than order price.

$(TYPEDSIGNATURES)

This function executes a limit order `o` at a given `date` for an asset `ai` only if the price is lower (for buy orders) or higher (for sell orders) than the order price.
"""
function limitorder_ifprice!(s::Strategy{Sim}, o::AnyLimitOrder, date, ai; kwargs...)
    @ifdebug PRICE_CHECKS[] += 1
    pbs, triggered = _istriggered(o, date, ai)
    if triggered
        # Order might trigger on high/low, but execution uses the *close* price.
        limitorder_ifvol!(s, o, date, ai; kwargs...)
    elseif o isa Union{AnyFOKOrder,AnyIOCOrder}
        if cancel!(s, o, ai; err=NotMatched(o.price, pbs, 0.0, 0.0))
            nothing
        end
    else
        missing
    end
end

@doc """ Determines if a trade should succeed based on the volume of the candle compared to the order amount.

$(TYPEDSIGNATURES)

This function calculates the ratio of the volume of the candle (`cdl_vol`) to the order amount.
Depending on the ratio, it determines if the trade should succeed and returns a boolean indicating the result along with the actual amount that can be filled.
"""
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

@doc """ Executes a limit order at a particular time according to volume.

$(TYPEDSIGNATURES)

This function executes a limit order `o` at a given `date` for an asset `ai` based on the volume of the candle compared to the order amount. It checks if the trade should succeed and performs the trade if conditions are met.
"""
function limitorder_ifvol!(s::Strategy{Sim}, o::AnyLimitOrder, date, ai; kwargs...)
    @ifdebug VOL_CHECKS[] += 1
    ans::Union{Missing,Nothing,Trade} = missing
    cdl_vol = st.volumeat(ai, date)
    amount = unfilled(o)
    @deassert amount > 0.0
    if o isa AnyFOKOrder # check for full fill
        # FOK can only be filled with max amount, so use max_depth=1
        triggered, actual_amount = _fill_happened(amount, cdl_vol; max_depth=1)
        if triggered
            @deassert amount == actual_amount
            ans = trade!(s, o, ai; price=o.price, date, actual_amount, kwargs...)
        else
            if cancel!(
                s, o, ai; err=NotMatched(o.price, priceat(s, o, ai, date), amount, cdl_vol)
            )
                ans = nothing
            end
        end
        @deassert !isqueued(o, s, ai)
    else
        # GTC and IOC can be partially filled so allow for amount reduction (max_depth=4)
        triggered, actual_amount = _fill_happened(
            amount, cdl_vol; max_depth=4, max_reduction=0.1
        )
        if triggered
            @deassert actual_amount > amount * 0.1
            ans = if o isa AnyPostOnlyOrder && o.date == date
                cancel!(s, o, ai; err=OrderCanceled(o))
                nothing
            else
                trade!(s, o, ai; price=o.price, date, actual_amount, kwargs...)
            end
        else
            # Cancel IOC orders if partially filled
            if o isa AnyIOCOrder &&
                !isfilled(ai, o) &&
                cancel!(s, o, ai; err=NotFilled(amount, cdl_vol))
                ans = nothing
            end
        end
        @deassert o isa AnyGTCOrder || !isqueued(o, s, ai)
    end
    ans
end
