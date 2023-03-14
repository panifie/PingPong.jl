module Checks
using ..Types.Instances
using ..Types.Orders
using Accessors: setproperties
using Lang: Option, @ifdebug
using Misc: isstrictlysorted

struct SanitizeOn end
struct SanitizeOff end

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
function sanitize_amount(inst::AssetInstance, amount)
    if inst.limits.amount.min > 0 && amount < inst.limits.amount.min
        inst.limits.amount.min
    elseif inst.precision.amount < 0 # has to be a multiple of 10
        max(toprecision(Int(amount), 10), inst.limits.amount.min)
    else
        toprecision(amount, inst.precision.amount)
    end
end

@doc """ See `sanitize_amount`.
"""
function sanitize_price(inst::AssetInstance, price)
    if inst.limits.price.min > 0 && price < inst.limits.price.min
        inst.limits.price.min
    else
        max(toprecision(price, inst.precision.price), inst.limits.price.min)
    end
end

function _cost_msg(asset, direction, value)
    "The cost of the order ($asset) is $direction market minimum of $value"
end

@doc """ The cost of the order should not be below the minimum for the exchange.
"""
function checkmincost(inst::AssetInstance, price, amount)
    iszero(inst.limits.cost.min) ||
        @assert price * amount >= inst.limits.cost.min _cost_msg(
            inst.asset, "below", inst.limits.cost.min
        )
end
@doc """ The cost of the order should not be above the maximum for the exchange.
"""
function checkmaxcost(inst::AssetInstance, price, amount)
    iszero(inst.limits.cost.max) || @assert price * amount < inst.limits.cost.min _cost_msg(
        inst.asset, "above", inst.limits.cost.max
    )
end

@doc """ Checks that the last price given is below maximum, and the first is above minimum.
In other words, it expects all given prices to be already sorted."""
function checkcost(inst::AssetInstance, amount, p1, prices...)
    for p in Iterators.reverse(prices)
        isnothing(p) || (checkmaxcost(inst, amount, p); break)
    end
    checkmincost(inst, amount, p1)
end
function checkcost(inst::AssetInstance, amount, p1)
    checkmaxcost(inst, amount, p1)
    checkmincost(inst, amount, p1)
end

@doc """ Checks that the given prices are sorted. """
function check_monotonic(prices...)
    @assert isstrictlysorted(Iterators.filter(!isnothing, prices)...) "Prices should be sorted, e.g. stoploss < price < takeprofit"
end

export SanitizeOn, SanitizeOff

end
