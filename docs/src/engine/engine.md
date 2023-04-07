# Engine

Within the PingPong "model" we use _ping!_ and _pong!_ functions to communicate between _strategies_ and _executors_. The executor "pings" the strategy, impliying that the strategy should do, or return something. The strategy instead "pongs" the executor, expecting it to do, or return something.

The user of the bot, generally, only writes `ping!` functions within their strategies. In the case the user requires custom behaviour that is not implemented by the framework, they might be required to write `pong!` functions.

Other trading bots offer a set of methods that the user can implement for tuning purposes, usually tied to the super class of the strategy. 
Within PingPong instead, our convention is to only deal with `ping!` and `pong!` functions, such that you know that whenever a _pong!_ call is done from the strategy, that is a point of possible divergence between simulation and live execution.

In fact, ping and pong functions are implemented such that they dispatch differently according to the execution mode of the strategy.

There are 3 execution modes: 
- `Sim`: what the backtester uses to run the simulations
- `Paper`: the dry run mode, that runs the bot like it would in live, working with live data feeds and simulating order execution with live prices.
- `Live`: like `Paper` but with order execution being actually forwarded to CCXT.

Therefore if the strategy is instantiated in `Sim` mode, calling `pong!(s, ...)`, where s is the strategy object of type `Strategy{Sim, S, E}`, the `pong!` function will dispatch to the `Sim` execution method.
`S` and `E` are the other two parameters which a strategy type requires for concretization.
- `S<:Symbol`: the symbol that matches the module name of the strategy, like `:Example`
- `E<:ExchangeID`: The symbol _already checked_ to match a valid CCXT exchange, which will be the exchange that the strategy will operate on.

To realize the `pong!` dispatch convention, you can expect the first argument of every pong function to be the strategy object itself, while ping function might have either the strategy object or the type of the strategy as first argument (`Type{Strategy{...}}`).
    
### API
```@autodocs
Modules = [PingPong.Engine, PingPong.Engine.Instances, PingPong.Engine.Collections]
```
