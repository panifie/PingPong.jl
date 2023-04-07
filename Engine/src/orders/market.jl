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


@doc "Creates a simulated market order."
function Executors.pong!(
    s::Strategy{Sim}, t::Type{<:Order{<:MarketOrder}}, ai; amount, kwargs...
)
    o = marketorder(s, ai, amount; type=t, kwargs...)
    isnothing(o) && return nothing
    queue!(s, o, ai)
    limitorder_ifprice!(s, o, o.date, ai)
end

@doc "Progresses a simulated market order."
function Executors.pong!(
    s::Strategy{Sim}, o::Order{<:MarketOrder}, date::DateTime, ai; kwargs...
)
    limitorder_ifprice!(s, o, date, ai)
end
