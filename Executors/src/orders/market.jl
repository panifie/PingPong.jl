const _MarketOrderState1 = NamedTuple{
    (:take, :stop, :filled, :trades),
    Tuple{Option{Float64},Option{Float64},Vector{Float64},Vector{Trade}},
}

function marketorder(
    ai::AssetInstance,
    price,
    amount,
    committed,
    ::SanitizeOff;
    type=MarketOrder{Buy},
    date,
    take=nothing,
    stop=nothing,
)
    ismonotonic(stop, price, take) || return nothing
    iscost(ai, amount, stop, price, take) || return nothing
    Orders.Order(
        ai,
        type;
        date,
        price,
        amount,
        committed,
        attrs=limit_order_state(take, stop, committed),
    )
end
