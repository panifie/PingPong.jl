@doc "Abstract type for order errors."
abstract type OrderError <: Exception end
@doc "There wasn't enough cash to setup the order."
@kwdef struct NotEnoughCash{T<:Real} <: OrderError
    required::T
end
@doc "There weren't enough orders in the orderbook to match the amount."
@kwdef struct NotEnoughLiquidity <: OrderError end
@doc "Couldn't fullfill the order within the requested period."
@kwdef struct OrderTimeOut <: OrderError
    order::O where {O<:Order}
end
@doc "Price and amount at execution time was outside the available ranges. (FOK)"
@kwdef struct NotMatched{T<:Real} <: OrderError
    price::T
    this_price::T
    amount::T
    this_volume::T
end
@doc "There wasn't enough volume to fill the order completely. (IOC)"
@kwdef struct NotFilled{T<:Real} <: OrderError
    amount::T
    this_volume::T
end
@doc "A generic error order prevented the order from being setup."
@kwdef struct OrderFailed <: OrderError
    msg::Any
end

@doc "When an order has been directly canceled by a strategy."
@kwdef struct OrderCanceled <: OrderError
    order::O where {O<:Order}
end

@doc "Order has been replaced by a liquidation order."
@kwdef struct LiquidationOverride <: OrderError
    order::O where {O<:Order}
    liqprice::T where {T<:Real}
    liqdate::DateTime
    p::PositionSide
end

@doc "Abstract type for syncing errors (live)."
abstract type SyncError <: Exception end
