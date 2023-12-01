# Stats Module Documentation

The `Stats` module provides functions for analyzing the outcomes of backtest runs within the trading strategy framework.

### Resampling Trades

Using the [`Stats.resample_trades`](@ref) function, trades can be resampled to a specified time frame. This aggregates the profit and loss (PnL) of each trade for every asset in the strategy over the given period.

```julia
using PingPong
using Stats

strategy_instance = strategy(:Example)
Stats.resample_trades(strategy_instance, tf"1d")
```

In the example above, all trades are resampled to a daily resolution (`1d`), summing the PnL for each asset within the strategy.

### Trade Balance Calculation

The [`Stats.trades_balance`](@ref) function calculates the cumulative balance over time for a given time frame, using the `cum_total` column as a reference. This function relies on the prior resampling of trades through `resample_trades`.

```julia
Stats.trades_balance(strategy_instance, tf"1d")
```

### Performance Metrics

The module includes implementations of common trading performance [metrics](./API/stats.md) such as Sharpe ratio (`sharpe`), Sortino ratio (`sortino`), Calmar ratio (`calmar`), and expectancy (`expectancy`).

```julia
Stats.sharpe(strategy_instance, tf"1d", rfr=0.01)
Stats.sortino(strategy_instance, tf"1d", rfr=0.01)
Stats.calmar(strategy_instance, tf"1d")
Stats.expectancy(strategy_instance, tf"1d")
```

Each of these functions calculates the respective metric over a daily time frame, with `rfr` representing the risk-free rate, which is an optional parameter for the Sharpe and Sortino ratios.

### Multi-Metric Calculation

To calculate multiple metrics simultaneously, use the `multi` function. It allows for the normalization of results, ensuring metric values are constrained between 0 and 1.

```julia
Stats.multi(strategy_instance, :sortino, :calmar; tf=tf"1d", normalize=true)
```

The `normalize` option normalizes the metric values by dividing by a predefined constant and then clipping the results to the range [0, 1].