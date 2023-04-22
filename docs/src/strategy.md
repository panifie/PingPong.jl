# Strategy interface

## Load a strategy

The strategy is instantiated by loading a julia module at runtime.

```julia
using PingPong
cfg = Config(:kucoin) # Load the configuration, choosing kucoin as exchange
strategy!(:Example, cfg) # Load the Example strategy
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

After the strategy module is imported the strategy is instantiated by calling the `ping!(::Type{S}, ::LoadStrategy, cfg)` function.

```julia
> typeof(s)
Engine.Strategies.Strategy37{:Example, ExchangeTypes.ExchangeID{:kucoin}(), :USDT}
```

See here how the `load` method is defined.

```julia
module Example
using Engine.Strategies
using ExchangeTypes

const NAME = :Example
const EXCID = ExchangeID(:bybit)
const S{M} = Strategy{M,NAME,typeof(EXCID)}
const TF = tf"1m"

function ping!(::Type{S}, ::LoadStrategy, config)
    assets = marketsid(S)
    s = Strategy(Example, assets; config)
    s
end

end
```

See that the `load` method dispatches on the strategy _type_ with `cfg` as argument of type `Misc.Config`.

As a rule of thumb if the method should be called before the strategy is construct, then it dispatches to the strategy type (`Type{S}`), otherwise the strategy instance (`S`). For convention the module property `S` of your strategy module, declares the strategy type (`const S = Strategy{name, exc}`).

## Strategy interface

- `ping!(::Type{S}, ::LoadStrategy, config)`: loads the strategy
- `ping!(::S, ::WarmupPeriod)`: returns how much data the strategy needs on startup
- `ping!(::S, ::DateTime, ::Context)`: the "main" strategy function, called once per candle in backtest and once per _throttle_ during live.

### API

```@docs
Engine.Strategy
```

```@autodocs
Modules = [Engine.Strategies]
Filter = filter_strategy
```
