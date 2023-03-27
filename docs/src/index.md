## Quickstart
Launch julia and activate the package:
```shell
git clone https://github.com/untoreh/PingPong.jl
cd PingPong.jl
julia --project=.
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
using Engine.Types.Collections: stub!
let data = bn.binanceload(pairs)
    stub!(s.universe, data)
end
```
Backtest the strategy within the period available from the loaded data.
```julia
using Engine.Executors.Backtest: Backtest as bt
bt.backtest!(s)
```

## Main Libraries
- [Engine](./engine/engine.md): The actual backtest engine (to be built).
- [Strategies](./strategy.md): Types and concept for building strategies.
- [Exchanges](./exchanges.md): Loads exchanges instances, markets and pairlists, based on [ccxt](https://docs.ccxt.com/en/latest/manual.html).
- [Plotting](./plotting.md): Output plots for ohlcv data, indicators, backtests, based on [Makie](https://github.com/MakieOrg/Makie.jl).

## Helper libraries
- [Data](./data.md): Loading and saving ohlcv data (and more), based Zarr.
- [Stats](./stats.md): Statistics about backtests, and live operations.
- [Processing](./processing.md): Data cleanup, normalization, resampling functions.
- [Watchers](./watchers/watchers.md): Services for data pipelines, from sources to storage.
- [Misc](./misc.md): Ancillary stuff, like configuration, and some UI bits.
- [Analysis](./analysis.md): The bulk of indicators evaluation, depends of a bunch of (heavy) julia libraries like `CausalityTools` and `Indicators`.

## Infos
- [troubleshooting](./troubleshooting.md)
- [devnotes](./devnotes.md)
- [contacts](./contacts.md)
