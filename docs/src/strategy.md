# Strategy interface

## Loading
The strategy is instantiated by loading a julia module at runtime.
```julia
using Backtest
cfg = loadconfig!(:kucoin, cfg=Config()) # Load the configuration, choosing kucoin as exchange
loadstrategy!(:Macd, cfg) # Load the Macd strategy
```
The strategy is looked up insite the config under the `sources` key:
```toml
# Example config
[kucoin]
futures = true
[sources]
Macd = "cfg/strategies/Macd.jl" # the name of the module
```
The key is the name of the module (in this case `Macd`) which will be imported from the included file "cfg/strategies/Macd.jl".

After the strategy module is imported the strategy is instantiated according to the module name (the strategy type is parametric.)

```julia
s = Strategy(name)
end
