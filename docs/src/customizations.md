# Extending the framework/bot

We have parametrized types for strategies, assets/instances, orders, and trades.
The strategy parametrization is what allows us to implement the _ping pong_ model by separating simulations from live executions, the rest can be used to implement custom logic behaviour.
