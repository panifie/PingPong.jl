## HFT backtesting

The pingpong backtester (`SimMode`) relies on OHLCV data to execute trades. 

A few reasons why you might not want to backtest tick by tick:
- Bid/ask data is hard to find and very large in size, it is more resource expensive.
- Constructing order book data from trades history is guess work that introduces a lot of bias.
- Backtesting in such high details will likely overfit any strategy against a specific combination of market makers, more bias.
- Because of the high data requirements and computational costs you might be able to only backtest a few days, not giving you enough confidence in the backtest itself since it can't run across regime changes.

If you are still set in adding HFT backtesting there are two approaches: 
- The simpler one is to still use the OHLCV model, but construct the ohlcv from trades history building very short candles, like `1s`. The backtester simply iterates over timesteps, by default using the strategy base timeframe. If you choose `1s` as timeframe and feed it the correct candles it would be enough to run a backtest at the time resolution you require.
- The harder approach is to create a new `ExecMode`, let's call it `TickSimMode` and reimplement the desired logic starting from the `backtest!` function. Practically most of the logic for orders creation can be reused, but functions like `volumeat(ai, date)` or `openat,closeat`, etc... are used to calculate fills and slippage, which query the current candle, and you would need to customize those to calc the correct price/volume of the trade from the tick data, (see for example `limitorder_ifprice!`).
