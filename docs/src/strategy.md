# Strategy interface

## Load a strategy
The strategy is instantiated by loading a julia module at runtime.
```julia
using JuBot
cfg = loadconfig!(:kucoin, cfg=Config()) # Load the configuration, choosing kucoin as exchange
loadstrategy!(:Macd, cfg) # Load the Macd strategy
```
The strategy is looked up inside the config under the `sources` key:
```toml
# Example config
[kucoin]
futures = true
[sources]
Macd = "cfg/strategies/Macd.jl" # the name of the module
```
The key is the name of the module (in this case `Macd`) which will be imported from the included file "cfg/strategies/Macd.jl".

After the strategy module is imported the strategy is instantiated according to the module name (the strategy type is parametric).

```julia
s = Strategy(name)
```

```julia
> typeof(s)
Engine.Strategies.Strategy37{:Macd, ExchangeTypes.ExchangeID{:kucoin}(), :USDT}
```

## Familiarize with the data structures

``` @docs
Strategy
```

```@autodocs
Modules = [Engine.Strategies]
Filter = filter_strategy
```
