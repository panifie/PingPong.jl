## High-Frequency Trading (HFT) Backtesting Documentation

The `SimMode` class, also known as the pingpong backtester, utilizes Open-High-Low-Close-Volume (OHLCV) data to simulate the execution of trades.

### Reasons to Avoid Tick-by-Tick Backtesting
Tick-by-tick backtesting may not be ideal due to several factors:
- **Data Availability**: Bid/ask tick data is often difficult to obtain and can be extremely voluminous, leading to increased resource consumption.
- **Data Reconstruction**: Attempting to reconstruct order book data from trade history is speculative and can introduce significant bias.
- **Overfitting Risks**: High-detail backtesting can cause strategies to overfit to specific market maker behaviors, resulting in additional bias.
- **Computational Costs**: Intensive data and computational requirements may limit backtesting to a short time frame, insufficient for evaluating performance through different market conditions.

### Implementing HFT Backtesting
Should you decide to implement HFT backtesting, consider the following two approaches:

#### OHLCV-Based Approach
- A simpler method involves using the OHLCV model with extremely short-duration candles, such as `1s` candles. The backtester processes time steps, typically using the strategy's base timeframe. By selecting a `1s` timeframe and supplying the corresponding candles, you can achieve the desired time resolution for your backtest.

#### Tick-Based Approach
- A more complex method requires developing a new execution mode, which could be named `TickSimMode`. This involves adapting the `backtest!` function to handle tick data. While order creation logic may remain largely unchanged, functions like `volumeat(ai, date)` or `openat, closeat`, which currently fetch candle data, need to be modified. These functions should be tailored to compute the trade's actual price and volume from the tick data. This is analogous to customizing functions such as `limitorder_ifprice!` to work with tick data.

\```example
// Example of setting up a 1-second OHLCV backtest
// Note: Actual implementation details will vary based on your specific backtesting framework
SimMode backtester = new SimMode("1s");
backtester.loadData("path/to/1s_candle_data.csv");
backtester.run();
\```