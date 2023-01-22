module Checks
using ..Instances
using ..Orders
using Accessors: setproperties
using Lang: Option

function sanitize_price_amount(inst::AssetInstance, price, amount)
    sanitized_price = if inst.limits.price.min > 0 && price < inst.limits.price.min
        inst.limits.price.min
    else
        round(price; digits=inst.precision.price)
    end
    sanitized_amount = if inst.limits.amount.min > 0 && amount < inst.limits.amount.min
        inst.limits.amount.min
    else
        if inst.precision.amount < 0 # has to be a multiple of 10
            amt = Int(amount)
            max(amt - mod(amt, 10), inst.limits.amount.min)
        else
            round(amount; digits=inst.precision.amount)
        end
    end
    return (sanitized_price, sanitized_amount)
end

function check_cost(inst::AssetInstance, price, amount)
    @assert price * amount >= inst.limits.cost.min "The cost of the order ($(inst.asset)) \
        is below market minimum of $(inst.limits.cost.min)"
end

@doc "Ensures the order respect the minimum limits (not the maximum!) and precision for the market."
function sanitize_order(inst::AssetInstance{A, E}, o::Order{A, E})::Option{Order{A, E}} where {A, E}
    (price, amount) = sanitize_price_amount(inst, o.price, o.amount)
    o = setproperties(o; price, amount)
    check_cost(inst, o.price, o.amount)
    return o
end

export sanitize_order

end
