abstract type OrderError end
@doc "There wasn't enough cash to setup the order."
@kwdef struct NotEnoughCash{T<:Real} <: OrderError
    required::T
end
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
    msg::String
end
