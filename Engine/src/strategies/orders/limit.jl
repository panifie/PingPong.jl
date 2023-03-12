
# @doc "Create a sanitized order based on an asset instance."
# function Orders.Order(inst::AssetInstance, amount, price; kwargs...)
#     (amount, price) = sanitize_price_amount(inst, price, amount)
#     check_cost(inst, price, amount)
#     Orders.Order(inst.asset, inst.exchange[].id; amount, price, kwargs...)
# end

function LimitOrder(ai::AssetInstance, amount, price; stop_up=nothing, stop_down=nothing)
    @price! ai price
    @amount! ai amount
    check_cost(ai, price, amount)
    Orders.Order(ai; amount, price, attrs=(; stop_up, stop_down))
end
