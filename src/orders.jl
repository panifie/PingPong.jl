using Engine.Orders
using Engine.Instances
using Engine.Checks: sanitize_price_amount, check_cost

@doc "Create a sanitized order based on an asset instance."
function Order(inst::AssetInstance, amount, price; kwargs...)
    (amount, price) = sanitize_price_amount(inst, price, amount)
    check_cost(inst, price, amount)
    Orders.Order(inst.asset, inst.exchange[].id; amount, price, kwargs...)
end
