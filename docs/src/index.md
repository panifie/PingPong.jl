# Backtest docs

This backtest framework is comprised of different modules:

- [Engine](./engine.md): The actual backtest engine (to be built).
- [Exchanges](./exchanges.md): Loads exchanges instances, markets and pairlists, based on ccxt.
- [Data](./data.md): Loading and saving ohlcv data (and more), based Zarr.
- [Processing](./processing.md): Data cleanup, normalization, resampling functions.
- [Plotting](./plotting.md): Output plots for ohlcv data and indicators, based on pyecharts.
- [Analysis](./analysis.md): The bulk of indicators evaluation, depends of a bunch of (heavy) julia libraries like `CausalityTools` and `Indicators`.
- [Misc](./misc.md): Ancillary stuff, like configuration, and some UI bits.

