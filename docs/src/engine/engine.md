# Engine

Within the PingPong "model", we use the _ping!_ and _pong!_ functions to communicate between _strategies_ and _executors_. The executor "pings" the strategy, implying that the strategy should do or return something. On the other hand, the strategy "pongs" the executor, expecting it to do or return something.

In the PingPong framework, the user generally only writes `ping!` functions within their strategies. However, if the user requires custom behavior that is not implemented by the framework, they may need to write `pong!` functions.

Unlike other trading bots that offer a set of methods for tuning purposes, usually tied to the super class of the strategy, PingPong conventionally deals only with `ping!` and `pong!` functions. This allows you to know that whenever a _pong!_ call is made from the strategy, it is a point where simulation and live execution may diverge.

The ping and pong functions are implemented in a way that they dispatch differently according to the execution mode of the strategy. There are 3 execution modes:

- `Sim`: This mode is used by the backtester to run simulations.
- `Paper`: This is the dry run mode, which runs the bot as if it were live, working with live data feeds and simulating order execution with live prices.
- `Live`: Similar to `Paper`, but with order execution actually forwarded to a live exchange (e.g., through CCXT).

If the strategy is instantiated in `Sim` mode, calling `pong!(s, ...)`, where `s` is the strategy object of type `Strategy{Sim, N, E, M, C}`, the `pong!` function will dispatch to the `Sim` execution method. The other two parameters, `N` and `E`, are required for concretizing the strategy type:
- `N<:Symbol`: The symbol that matches the module name of the strategy, such as `:Example`.
- `E<:ExchangeID`: The symbol that has already been checked to match a valid CCXT exchange, which will be the exchange that the strategy will operate on.
- `M<:MarginMode`: The margin mode of the strategy, which can be `NoMargin`, `IsolatedMargin`, or `CrossMargin`. Note that the margin mode also has a type parameter to specify if hedged positions (having long and short on the same asset at the same time) are allowed. `Isolated` and `Cross` are shorthand for `IsolatedMargin{NotHedged}` and `CrossMargin{NotHedged}`.
- `C`: The symbol of the `CurrencyCash` that represents the balance of the strategy, e.g., `:USDT`.

To follow the `pong!` dispatch convention, you can expect the first argument of every pong function to be the strategy object itself, while ping functions might have either the strategy object or the type of the strategy as the first argument (`Type{Strategy{...}}`).
    

