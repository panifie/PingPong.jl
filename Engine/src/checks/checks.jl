module Checks
using ..Instances
using ..Orders
using Accessors: setproperties
using Lang: Option

toprecision(n::Int, prec::Int) = n - mod(n, prec)
@doc "When precision is a float it represents the pip."
toprecision(n::Float64, prec::Float64) = n - mod(n, prec)
@doc "When precision is a Integer it represents the number of decimals."
toprecision(n::Float64, prec::Int) = round(n; digits=prec)

@doc """Price and amount value of an order are adjusted by subtraction.

Which means that their output values will always be lower than their input, **except** \
for the case in which their values would fall below the exchange minimums. In such case \
the exchange minimum is returned.
"""
function sanitize_price_amount(inst::AssetInstance, price, amount)
    sanitized_price = if inst.limits.price.min > 0 && price < inst.limits.price.min
        inst.limits.price.min
    else
        max(toprecision(price, inst.precision.price), inst.limit.price.min)
    end
    sanitized_amount = if inst.limits.amount.min > 0 && amount < inst.limits.amount.min
        inst.limits.amount.min
    elseif inst.precision.amount < 0 # has to be a multiple of 10
        max(toprecision(Int(amount), 10), inst.limits.amount.min)
    else
        toprecision(amount, inst.precision.amount)
    end
    return (sanitized_price, sanitized_amount)
end

function check_cost(inst::AssetInstance, price, amount)
    @assert price * amount >= inst.limits.cost.min "The cost of the order ($(inst.asset)) \
        is below market minimum of $(inst.limits.cost.min)"
end

@doc "Ensures the order respect the minimum limits (not the maximum!) and precision for the market."
function sanitize_order(
    inst::AssetInstance{A,E}, o::Order{A,E}
)::Option{Order{A,E}} where {A,E}
    (price, amount) = sanitize_price_amount(inst, o.price, o.amount)
    o = setproperties(o; price, amount)
    check_cost(inst, o.price, o.amount)
    return o
end

export sanitize_order

end
