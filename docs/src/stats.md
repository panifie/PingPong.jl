# Stats

Within the stats package there are function that help you analyze the outcome of a backtest run.

``` julia
using PingPong
using Stats

s = strategy(:Example)
Stats.resample_trades(s, tf"1d")
```

In this case all the trades have been resampled with one day resolution, summing pnl of each trade for each trades asset in the strategy.

``` julia
Stats.trades_balance(s, tf"1d")
```

`trades_balance` (which depends on `trades_resample`) calculates the cumulative total balance at each time frame using the column `cum_total`.

## Metrics

Some common metrics used to analyze pnl are implemented, like `sharpe`, `sortino`, `calmar`, and `expectancy`.

``` julia
Stats.sharpe(s, tf"1d", rfr=0.01)
Stats.sortino(s, tf"1d", rfr=0.01)
Stats.calmar(s, tf"1d")
Stats.expectancy(s, tf"1d")
```

The function `multi` is used to calc multiple metrics.

``` julia
Stats.multi(s, :sortino, :calmar; tf=tf"1d", normalize=true)
```

`normalize` clamps the metric such that its value is always between 0 and 1. It does so by dividing by an arbitrary constant the value and then clipping between zero and one.
