# PingPong docs


This backtest framework is comprised of different modules:

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
