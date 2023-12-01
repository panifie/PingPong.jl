## Custom Orders

This section demonstrates how to implement an OCO (One-Cancels-the-Other) order type for simulation purposes:

```julia
using OrderTypes: OrderType, @deforders

abstract type OCOOrderType{S} <: OrderType{S}
@deforders OCO
```

We can base our implementation on the existing constructor for limit orders and modify it to meet the requirements of an OCO order:

```julia
const _OCOOrderState = NamedTuple{(:committed, :filled, :trades, :twin), Tuple{Vector{Float64}, Vector{Float64}, Vector{Trade}, Ref{OCOOrder}}}

function oco_order_state(
    committed::Vector{T}, filled::Vector{Float64}=[0.0], trades::Vector{Trade}=Vector{Trade}()
) where T
    _OCOOrderState((committed, filled, trades, Ref{OCOOrder}()))
end

function ocoorder(
    ai::AssetInstance,
    ::SanitizeOff;
    price_lower::Float64,
    amount_lower::Float64,
    price_upper::Float64,
    amount_upper::Float64,
    committed_lower::Vector{Float64},
    committed_upper::Vector{Float64},
    date::Datetime
)
    ismonotonic(price_lower, price_upper) || return nothing
    iscost(ai, amount_lower, price_lower) || return nothing
    iscost(ai, amount_upper, price_upper) || return nothing

    lower_order = OrderTypes.Order(
        ai,
        OCOOrderType{Sell};
        date,
        price_lower,
        amount_lower,
        committed_lower,
        attrs=oco_order_state(committed_lower)
    )
    upper_order = OrderTypes.Order(
        ai,
        OCOOrderType{Buy};
        date,
        price_upper,
        amount_upper,
        committed_upper,
        attrs=oco_order_state(committed_upper)
    )

    lower_order.attrs[:twin] = upper_order
    upper_order.attrs[:twin] = lower_order
    return lower_order
end
```

Next, we introduce two `pong!` functions to handle creating and updating simulated OCO orders:

```julia
@doc "Creates a simulated OCO order."
function pong!(
    s::Strategy{Sim}, ::Type{Order{<:OCOOrderType}}, ai; date, kwargs...
)
    o = ocoorder(s, ai; date, kwargs...)
    isnothing(o) && return nothing
    iscommittable(s, o, ai) || return nothing
    # TODO: Implement logic to execute the order and return resulting trades.
end

@doc "Updates a simulated OCO order."
function pong!(
    s::Strategy{Sim}, ::Type{<:Order{OCOOrderType}}, date::Datetime, ai; kwargs...
)
    o = ocoorder(s, ai; date, kwargs...)
    isnothing(o) && return nothing
    iscommittable(s, o, ai) || return nothing
    iscommittable(s, o.attrs[:twin], ai) || return nothing
    # TODO: Implement logic to execute the order update and return resulting trades.
end
```

## Custom Instruments

We can extend instruments to create new types such as `Asset` and `Derivative`, which are subtypes of `AbstractAsset`. They are named using the CCXT convention (`QUOTE/BASE:SETTLE`), and it's expected that all instruments define a base and a quote currency.

## Instances and Exchanges

Asset instances are parameterized by the type of the asset (e.g., asset, derivative) and the exchange they are associated with. By using `ExchangeID` as a parameter, we can fine-tune the behavior for specific exchanges.

For example, if we want to handle OCO orders differently across exchanges in live mode, we can define `pong!` functions that are specialized based on the exchange parameter of the asset instance.

```julia
function pong!(
    s::Strategy{Live}, 
    ::Type{Order{<:OCOOrderType}}, 
    ai::AssetInstance{A, ExchangeID{:bybit}}; 
    date, 
    kwargs...
)
    # Replace the following comment with the actual call to a private method of the ccxt exchange class to execute the order.
    ### Call some private method of the ccxt exchange class to execute the order
end
```

The function above is designed to handle asset instances that are specifically tied to the `bybit` exchange.