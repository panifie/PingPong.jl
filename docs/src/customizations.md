# Extending the framework/bot

We have parametrized types for strategies, assets/instances, orders, and trades.
The strategy parametrization is what allows us to implement the _ping pong_ model by separating simulations from live executions, the rest can be used to implement custom logic behaviour.

## Custom orders

For example this is a sketch on how we can implement an OCO order type for simulations:

```julia
using OrderTypes: OrderType, @deforders
abstract type OCOOrderType{S} <: OrderType{S}
@deforders OCO
```

We can use the limitorder constructor function as template and tweak it for what we would need for an OCO order:

```julia
const _OCOOrderState = NamedTuple{(:committed, :filled, :trades, :twin), Tuple{Vector{Float64}, Vector{Float64}, Vector{Float64}, Ref{OCOOrder{S where S}}}}
function oco_order_state(
    committed::Vector{T}, filled=[0.0], trades=Trade[]
) where {T}
    _OCOOrderState((committed, filled, trades, Ref{OCOOrder}()))
end
function ocoorder(
    ai::AssetInstance,
    ::SanitizeOff
    ;
    price_lower,
    amount_lower,
    price_upper,
    amount_upper,
    committed_lower,
    committed_upper,
    date,
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
        attrs=oco_order_state(nothing, nothing, committed),
    )
    upper_order = OrderTypes.Order(
        ai,
        OCOOrderType{Buy};
        date,
        price_lower,
        amount_lower,
        committed_lower,
        attrs=oco_order_state(nothing, nothing, committed),
    )
    lower_order.attrs[:twin] = upper_order
    upper_order.attrs[:twin] = lower_order
    return lower_order
end
```

Now we add two `pong!` functions, one for order creation, and one for updates.

```julia
@doc "Creates a simulated oco order."
function pong!(
    s::Strategy{Sim}, ::Type{Order{<:OCOOrderType}}, ai; date, kwargs...
)
    o = ocoorder(s, ai; date, kwargs...)
    isnothing(o) && return nothing
    iscommittable(s, o, ai) || return nothing
    ## add logic to execute and return trades...
end
@doc "Progresses a simulated oco order."
function pong!(
    s::Strategy{Sim}, ::Type{<:Order{OCOOrderType}}, date::Datetime, ai; kwargs...
)
    o = ocoorder(s, ai; date, kwargs...)
    isnothing(o) && return nothing
    iscommittable(s, o, ai) || return nothing
    iscommittable(s, o.attrs.twin, ai) || return nothing
    ## add logic to execute and return trades...
end
```

## Custom instruments

Instruments are also extendable, we have a simpler `Asset` and `Derivative` which are both subtypes of `AbstractAsset`, they are constructed following the CCXT naming scheme (`QUOTE/BASE:SETTLE`), the most basic
expectation for instruments is that they have a _base_and \_quote_ currency.

## Instances and exchanges

Asset instances are parametrized with the type of asset (asset,derivative...) and an exchange. The parametrization over `ExchangeID` allows us to customize the execution for particular exchanges.

For example if in live mode we wanted to support OCO orders differently across exchanges we could write `pong!` functions that dispatch depending on the exchange parameter of the asset instance.

```julia
function pong!(
    s::Strategy{Live}, ::Type{Order{<:OCOOrderType}}, ai::AssetInstance{A where A, ExchangeID{:bybit}}; date, kwargs...
)
### Call some private method of the ccxt exchange class to execute the order
end
```

The above function would only dispatch to asset instances belonging to the exchange `bybit`.
