module Checks
using ..Instances
using ..Orders
using Accessors: setproperties
using Lang: Option

@doc "Ensures the order respect the minimum limits (not the maximum!) and precision for the market."
function sanitize_order(inst::AssetInstance, o::Order)::Option{Order}
    amount = if inst.limits.amount.min > 0 && o.amount < inst.limits.amount.min
        inst.limits.amount.min
    else
        if inst.precision.amount < 0 # has to be a multiple of 10
            amt = Int(o.amount)
            max(amt - mod(amt, 10), inst.limits.amount.min)
        else
            round(o.amount; digits=inst.precision.amount)
        end
    end
    price = if inst.limits.price.min > 0 && o.price < inst.limits.price.min
        inst.limits.price.min
    else
        round(o.price; digits=inst.precision.price)
    end
    o = setproperties(o; price, amount)
    @assert o.price * o.amount >= inst.limits.cost.min "The cost of the order ($(o.asset)) \
        is below market minimum of $(inst.limits.cost.min)"
    return o
end

export sanitize_order

end
