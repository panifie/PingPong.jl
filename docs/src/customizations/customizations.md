# Extending the framework/bot

There are parametrized types for:
- strategies
- assets
- instances
- orders and trades.
- exchanges

The strategy parametrization is what allows us to implement the _ping pong_ model by separating simulations from live executions, the rest can be used to implement custom logic behaviour.

An exchange offers a unique order type? you can implement it by defining a new order type like:

``` julia
using OrderTypes
abstract type MyCustomOrderType{S} <: OrderType{S} end
```

Then you implement the functions where the logic diverges from standard market/limit orders. You might find that the order execution to be quite fine grained, which _should_ allow you to implement the cusomization by defining the minimum amount of functions possible while avoid touch things that might behave the same as limit or market orders. If that is not the case, file an issue.

Another common thing that can happen is that the exchange where you are trading behaves inconsistently over the interface. Despite CCXT unifying a good chunk of the api, many exchanges still remain where the private api might be required. Again look into the api and see what is worth overriding, if some function is too big, we might split it and allow for easier dispatching.

Many functions take the strategy as arguments, and strategies always have their name within the types parameters, so you can always define "snowflake" functions that only work for a specific strategy, use this flexibility wisely as to avoid complexity bankruptcy.
