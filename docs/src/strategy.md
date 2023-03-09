# Strategy interface

## Load a strategy
The strategy is instantiated by loading a julia module at runtime.
```julia
using PingPong
cfg = loadconfig!(:kucoin, cfg=Config()) # Load the configuration, choosing kucoin as exchange
loadstrategy!(:Example, cfg) # Load the Example strategy
```
The strategy is looked up inside the config under the `sources` key:
```toml
# Example config
[kucoin]
futures = true
[sources]
Example = "cfg/strategies/Example.jl" # the name of the module
```
The key is the name of the module (in this case `Example`) which will be imported from the included file "cfg/strategies/Example.jl".

After the strategy module is imported the strategy is instantiated according to the module name (the strategy type is parametric).

```julia
s = Strategy(name)
```

```julia
> typeof(s)
Engine.Strategies.Strategy37{:Example, ExchangeTypes.ExchangeID{:kucoin}(), :USDT}
```

## Familiarize with the data structures

``` @docs
Strategy
```

```@autodocs
Modules = [Engine.Strategies]
Filter = filter_strategy
```
