# What is PingPong?

PingPong is a bot for running automated trading strategies. It allows for interactive experimentation of new strategies through the julia REPL, and their live deployment to trading exchanges with almost zero code replication.

The bot is based around the concept of _strategies_. A strategy requires a primary currency which represents its balance and a primary exchange where all the orders will be forwarded (and against which they will be checked for validity).

Writing a pingpong strategy is equivalent to writing a julia module, that the bot will load (either dynamically or statically on deployments). Within the module you import the pingpong interface, such that you can specialize `ping!` entry functions relative only to your strategy, the rest is up to you.

The framework provides a long list of convenience or utility functions to manipulate the strategy and assets objects defined in different modules. In fact the bot is quite modular and is made of almost 30 packages, even though the majority of them is required to actually run the bot.

From the strategy you can manage orders through `pong!` functions and expect them to be executed during simulation and live trading (through the CCXT library) while returning _the same data structures_ even if populated through different means.

The advantage of PingPong over trading bots written in other programming languages is its flexibility thanks to the julia parametric type system that allows to extend the bot by specializing functions to perform ad hoc logic. An exchange is behaving differently compared to others? You can specialize the `balance` function over only that particular exchange by defining:

``` julia
balance(exc::Exchange{:MyQuirkyExchange}, args...) ... end
```

where `:MyQuirkyExchange` is the `ExchangeID` symbol of the exchange you are targeting. 

This is how strategy `ping!` functions also dispatch, because the strategies always have in their type parameters the `Symbol` which matches the module of the strategy itself. Indeed you cannot define multiple strategies with the same name.
And it is also how we are able to have almost zero code duplication between simulation and live trading, the execution mode is just another type parameter of the strategy.

The bot has tools to download, clean and store data, that make use of popular julia libraries. See [Data](data.md), and tools to resample time series see [Processing](processing.md).

It can track live data like tickers, trades, ohlcv, see [Watchers](watchers/watchers.md).

It can compute statistics about backtest runs, see [Stats](stats.md)

It can generate interactive and fully browsable plots for ohlcv data, indicators and backtesting runs, see [Plotting](plotting.md)

## Quickstart

Launch julia and activate the package:

```shell
git clone https://github.com/panifie/PingPong.jl
cd PingPong.jl
julia --project=./PingPong
```

Instantiate dependencies:

```julia
using Pkg: Pkg
Pkg.instantiate()
using PingPong
```

Load the default strategy, which you can look up at `./user/strategies/Example.jl`

```julia
using Engine.Strategies
s = strategy(:Example)
```

Download some data:

```julia
using Instruments
pairs = raw.(s.universe.data.asset)
using Scrapers: BinanceData as bn
bn.binancedownload(pairs)
```

Load the data into the strategy universe:

```julia
using Engine.Collections: stub!
let data = bn.binanceload(pairs)
    stub!(s.universe, data)
end
```

Backtest the strategy within the period available from the loaded data.

```julia
using Engine.Executors.SimMode: SimMode as bt
bt.backtest!(s)
```

Plot the simulated trades:

```julia
PingPong.plots!()

```

## Packages

- [Engine](./engine/engine.md): The actual backtest engine.
- [Strategies](./strategy.md): Types and concept for building strategies.
- [Exchanges](./exchanges.md): Loads exchanges instances, markets and pairlists, based on [ccxt](https://docs.ccxt.com/en/latest/manual.html).
- [Plotting](./plotting.md): Output plots for ohlcv data, indicators, backtests, based on [Makie](https://github.com/MakieOrg/Makie.jl).
- [Data](./data.md): Loading and saving ohlcv data (and more), based Zarr.
- [Stats](./stats.md): Statistics about backtests, and live operations.
- [Processing](./processing.md): Data cleanup, normalization, resampling functions.
- [Watchers](./watchers/watchers.md): Services for data pipelines, from sources to storage.
- [Misc](./misc.md): Ancillary stuff, like configuration, and some UI bits.
- [Analysis](./analysis.md): The bulk of indicators evaluation, depends of a bunch of (heavy) julia libraries like `CausalityTools` and `Indicators`.

## Infos

- [Troubleshooting](./troubleshooting.md)
- [Devdocs](./devdocs.md)
- [Contacts](./contacts.md)
