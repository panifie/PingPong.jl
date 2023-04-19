module Checks
using Lang: Option, @ifdebug
using Misc: isstrictlysorted
using Instances
using OrderTypes

struct SanitizeOn end
struct SanitizeOff end

cost(price, amount) = price * amount
withfees(cost, fees) = muladd(cost, fees, cost)

_minusmod(n, prec) = begin
    m = mod(n, prec)
    isapprox(m, prec) ? n : n - m
end

toprecision(n::Integer, prec::Integer) = _minusmod(n, prec)
@doc "When precision is a float it represents the pip."
function toprecision(n::T where {T<:Union{Integer,AbstractFloat}}, prec::AbstractFloat)
    _minusmod(n, prec)
end
@doc "When precision is a Integereger it represents the number of decimals."
toprecision(n::AbstractFloat, prec::Integer) = round(n; digits=prec)

@doc """Price and amount value of an order are adjusted by subtraction.

Which means that their output values will always be lower than their input, **except** \
for the case in which their values would fall below the exchange minimums. In such case \
the exchange minimum is returned.
"""
function sanitize_amount(ai::AssetInstance, amount)
    if ai.limits.amount.min > 0 && amount < ai.limits.amount.min
        ai.limits.amount.min
    elseif ai.precision.amount < 0 # has to be a multiple of 10
        max(toprecision(Int(amount), 10), ai.limits.amount.min)
    else
        toprecision(amount, ai.precision.amount)
    end
end

@doc """ See `sanitize_amount`.
"""
function sanitize_price(ai::AssetInstance, price)
    if ai.limits.price.min > 0 && price < ai.limits.price.min
        ai.limits.price.min
    else
        max(toprecision(price, ai.precision.price), ai.limits.price.min)
    end
end

function _cost_msg(asset, direction, value, cost)
    "The cost ($cost) of the order ($asset) is $direction market minimum of $value"
end

function ismincost(ai::AssetInstance, price, amount)
    iszero(ai.limits.cost.min) || begin
        cost = price * amount
        cost >= ai.limits.cost.min
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
    iszero(ai.limits.cost.max) || begin
        cost = price * amount
        cost < ai.limits.cost.max
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
function checkcost(ai::AssetInstance, amount, p1)
    checkmaxcost(ai, amount, p1)
    checkmincost(ai, amount, p1)
end
function iscost(ai::AssetInstance, amount, prices...)
    _checkcost(ismincost, ismaxcost, ai, amount, prices...)
    true
end
function iscost(ai::AssetInstance, amount, p1)
    ismaxcost(ai, amount, p1)
    ismincost(ai, amount, p1)
end

ismonotonic(prices...) = isstrictlysorted(Iterators.filter(!isnothing, prices)...)
@doc """ Checks that the given prices are sorted. """
function check_monotonic(prices...)
    @assert ismonotonic(prices...) "Prices should be sorted, e.g. stoploss < price < takeprofit"
    return true
end

export SanitizeOn, SanitizeOff, cost, withfees

end
