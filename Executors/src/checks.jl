module Checks
using Lang: Option, @ifdebug, @deassert
using Misc: isstrictlysorted, toprecision, ltxzero
using Instances
using Strategies: NoMarginStrategy, IsolatedStrategy, Strategy
using OrderTypes
using Base: negate

struct SanitizeOn end
struct SanitizeOff end

@doc "The cost of a trade is always *absolute*. (while fees can also be negative.)"
cost(price, amount) = abs(price * amount)
cost(price, amount, leverage) = abs(price * amount) / leverage
@doc "When increasing a position fees are added to the currency spent."
function withfees(cost, fees, ::T) where {T<:Union{IncreaseOrder,Type{<:IncreaseOrder}}}
    @deassert cost > 0.0
    muladd(cost, fees, cost)
end
@doc "When exiting a position fees are deducted from the received currency."
function withfees(cost, fees, ::T) where {T<:Union{ReduceOrder,Type{<:ReduceOrder}}}
    @deassert cost > 0.0
    muladd(negate(cost), fees, cost)
end

checkprice(_::NoMarginStrategy, _, _, _) = nothing
@doc "The price of a trade for long positions should never be below the liquidation price."
function checkprice(_::IsolatedStrategy, ai, actual_price, o::LongOrder)
    @assert actual_price > liqprice(ai, Long()) (o, actual_price, liqprice(ai, Long()))
end
@doc "The price of a trade for short positions should never be above the liquidation price."
function checkprice(_::IsolatedStrategy, ai, actual_price, o::ShortOrder)
    @assert actual_price < liqprice(ai, Short()) (o, actual_price, liqprice(ai, Short()))
end
@doc "Amount changes sign only after trade creation, it is always given as *positive*."
checkamount(actual_amount) = @assert actual_amount >= 0.0

@doc """Price and amount value of an order are adjusted by subtraction.

Which means that their output values will always be lower than their input, **except** \
for the case in which their values would fall below the exchange minimums. In such case \
the exchange minimum is returned.
"""
function sanitize_amount(ai::AssetInstance, amount)
    if ai.limits.amount.min > 0.0 && amount < ai.limits.amount.min
        ai.limits.amount.min
    elseif ai.precision.amount < 0.0 # has to be a multiple of 10
        max(toprecision(Int(amount), 10.0), ai.limits.amount.min)
    else
        toprecision(amount, ai.precision.amount)
    end
end

@doc """ See `sanitize_amount`.
"""
function sanitize_price(ai::AssetInstance, price)
    if ai.limits.price.min > 0.0 && price < ai.limits.price.min
        ai.limits.price.min
    else
        max(toprecision(price, ai.precision.price), ai.limits.price.min)
    end
end

function _cost_msg(asset, direction, value, cost)
    "The cost ($cost) of the order ($asset) is $direction market minimum of $value"
end

function ismincost(ai::AssetInstance, price, amount)
    let min = ai.limits.cost.min
        iszero(min) || begin
            cost = price * amount
            cost >= min
        end
    end
end
@doc """ The cost of the order should not be below the minimum for the exchange.
"""
function checkmincost(ai::AssetInstance, price, amount)
    @assert ismincost(ai, price, amount) _cost_msg(
        ai.asset, "below", ai.limits.cost.min, price * amount
    )
    return true
end
function ismaxcost(ai::AssetInstance, price, amount)
    let max = ai.limits.cost.max
        iszero(max) || begin
            cost = price * amount
            cost < max
        end
    end
end
@doc """ The cost of the order should not be above the maximum for the exchange.
"""
function checkmaxcost(ai::AssetInstance, price, amount)
    @assert ismaxcost(ai, price, amount) _cost_msg(
        ai.asset, "above", ai.limits.cost.max, price * amount
    )
    return true
end

function _checkcost(fmin, fmax, ai::AssetInstance, amount, prices...)
    ok = false
    for p in Iterators.reverse(prices)
        isnothing(p) || (fmax(ai, amount, p) && (ok = true; break))
    end
    ok || return false
    ok = false
    for p in prices
        isnothing(p) || (fmin(ai, amount, p) && (ok = true; break))
    end
    ok
end

@doc """ Checks that the last price given is below maximum, and the first is above minimum.
In other words, it expects all given prices to be already sorted."""
function checkcost(ai::AssetInstance, amount, prices...)
    _checkcost(checkmincost, checkmaxcost, ai, amount, prices...)
end
function checkcost(ai::AssetInstance; amount, price)
    checkmaxcost(ai, amount, price)
    checkmincost(ai, amount, price)
end
function iscost(ai::AssetInstance, amount, prices...)
    @ifdebug check_monotonic(prices...)
    _checkcost(ismincost, ismaxcost, ai, amount, prices...)
end
function iscost(ai::AssetInstance; amount, price)
    ismaxcost(ai, amount, price) && ismincost(ai, amount, price)
end

ismonotonic(prices...) = isstrictlysorted(Iterators.filter(!isnothing, prices)...)
@doc """ Checks that the given prices are sorted. """
function check_monotonic(prices...)
    @assert ismonotonic(prices...) "Prices should be sorted, e.g. stoploss < price < takeprofit"
    return true
end

function isbroke(s::Strategy)
    ltxzero(s.cash) &&
        isempty(s.holdings) &&
        length(orderscount(s)) == 0

end

export SanitizeOn, SanitizeOff, cost, withfees, checkprice, checkamount

end
