# Extending the Framework/Bot

The framework provides parametrized types for various elements such as:
- Strategies
- Assets
- Instances
- Orders and Trades
- Exchanges

Parametrizing strategies enables the implementation of models like the _ping pong_ model, which distinguishes between simulations and live executions. The other parametrized types facilitate the introduction of custom logic and behavior.

### Implementing Custom Order Types

If an exchange offers a unique order type, you can define it by creating a new abstract type that inherits from `OrderType`. For example:

\```julia
using OrderTypes
abstract type MyCustomOrderType{S} <: OrderType{S} end
\```

After defining the new order type, implement the necessary functions that deviate from the standard market or limit order logic. Ideally, the order execution should be fine-grained, allowing for minimalistic customization. Only the essential functions differing from standard orders need definition, thereby avoiding modifications to existing shared behavior. If customization is not suitably granular, please file an issue for further enhancements.

### Dealing with Inconsistent Exchange Interfaces

Exchanges sometimes exhibit inconsistent behavior through their APIs. Although CCXT provides a unified layer for a significant portion of the exchange APIs, private APIs might still be needed for certain exchanges. Review the exchange-specific API to determine which functions could be overridden. If a function is particularly complex, we may consider splitting it to facilitate more straightforward customization.

### Strategy-Specific Functions

Functions often accept strategies as arguments, and strategy names are included within type parameters. This design allows for the creation of strategy-specific functions, also known as "snowflake" functions. While this flexibility is powerful, it should be used judiciously to prevent unnecessary complexity.

Remember to leverage this flexibility to enhance functionality without overcomplicating the system, thus avoiding "complexity bankruptcy."