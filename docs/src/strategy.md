# Strategy interface

## Setup a new strategy
The simplest way to create a strategy is to use the interactive generator which will prompt 
for the required set of options to set.

``` julia
julia> using PingPong
julia> PingPong.generate_strategy()
Strategy name: : MyNewStrategy

Timeframe:
   1m
 > 5m
   15m
   1h
   1d

Select exchange by:
 > volume
   markets
   nokyc

 > binance
   bitforex
   okx
   xt
   coinbase

Quote currency:
   USDT
   USDC
 > BTC
   ETH
   DOGE

Margin mode:
 > NoMargin
   Isolated

Activate strategy project at /run/media/fra/stateful-1/dev/PingPong.jl/user/strategies/MyNewStrategy? [y]/n: y

Add project dependencies (comma separated): Indicators
   Resolving package versions...
   [...]
  Activating project at `/run/media/fra/stateful-1/dev/PingPong.jl/user/strategies/MyNewStrategy`

┌ Info: New Strategy
│   name = "MyNewStrategy"
│   exchange = :binance
└   timeframe = "5m"
[ Info: Config file updated

Load strategy? [y]/n: 

julia> s = ans
```
Alternatively you can directly pass kwargs and skip interaction by passing `ask=false`.
``` julia
PingPong.generate_strat("MyNewStrategy", ask=false, exchange=:myexc)
```
or just use a config:
``` julia
cfg = PingPong.Config(exchange=:myexc)
PingPong.generate_strat("MyNewStrategy", cfg)
```
## Load a strategy

The strategy is instantiated by loading a julia module at runtime.

```julia
using PingPong
cfg = Config(exchange=:kucoin) # Constructs a configuration object, choosing kucoin as exchange
s = strategy(:Example, cfg) # Load the Example strategy
```

The key is the name of the module (in this case `Example`) which will be imported from the included file "cfg/strategies/Example.jl" or "cfg/strategies/Example/src/Example.jl".

After the strategy module is imported the strategy is instantiated by calling the `ping!(::Type{S}, ::LoadStrategy, cfg)` function.

```julia
> typeof(s)
Engine.Strategies.Strategy37{:Example, ExchangeTypes.ExchangeID{:kucoin}(), :USDT}
```

See here how the `load` method is defined.

```julia
module Example
using PingPong

const DESCRIPTION = "Example"
const EXC = :phemex
const MARGIN = NoMargin
const TF = tf"1m"

@strategyenv!

function ping!(::Type{<:SC}, ::LoadStrategy, config)
    assets = marketsid(S)
    s = Strategy(Example, assets; config)
    s
end

end
```

See that the `load` method dispatches on the strategy _type_ with `cfg` as argument of type `Misc.Config`.

As a rule of thumb if the method should be called before the strategy is constructed, then it dispatches to the strategy type (`Type{<:S}`), otherwise the strategy instance (`S`). For convention the module property `S` of your strategy module, declares the strategy type (`const S = Strategy{name, exc, ...}`) and `SC` defines the same strategy type where the exchange is still generic.

## Manual setup
If you want to create a strategy manually you can either:
- Copy the `user/strategies/Template.jl` to a new file in the same directory and customize it.
- Generate a new project in `user/strategies` and customize `Template.jl` to be your project entry file. The strategy `Project.toml` is used to store strategy config options. See other strategies examples for what the keys that are required.

For more advanced setups you can also use `PingPong` as a library, and construct the strategy object directly from your own module:

``` julia
using PingPong
using MyDownStreamModule
s = PingPong.Engine.Strategies.strategy(MyDownStreamModule)
```


## Strategy interface
Both `ping!` and `pong!` functions adhere to a convention for function signatures. The first argument is always 
either an instance of the _subject_ or its type, followed by the arguments of the function, with the last *non kw* argument being the _verb_ which describes the purpose of the function. KW arguments are optional and don't have any requirements. We can see below that `Type{S}` is the _subject, `config` is an argument, and `::LoadStrategy` is the _verb_.

## List of strategy ping! functions

```@docs
Engine.Strategies.ping!
```

## Removing a strategy
The function `remove_strategy` allows to discard a strategy by its name. It will delete the julia file or the project directory and optionally the config entry.

``` julia
julia> PingPong.remove_strategy("MyNewStrategy")
Really delete strategy located at /run/media/fra/stateful-1/dev/PingPong.jl/user/strategies/MyNewStrategy? [n]/y: y
[ Info: Strategy removed
Remove user config entry MyNewStrategy? [n]/y: y
```

## Strategy examples
Strategy examples can be found in the `user/strategies` folder, some strategies are single files like `Example.jl` while strategies like `BollingerBands` or `ExampleMargin` are project based.

