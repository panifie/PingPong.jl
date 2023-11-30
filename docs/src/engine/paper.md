# Running in Paper Mode
In order to configure a strategy in paper mode, you can define the default mode in `user/pingpong.toml` or in your strategy project's `Project.toml` file. Alternatively, pass the mode as a keyword argument:

```toml
[Example]
mode = "Paper"
```

```julia
using Strategies
s = strategy(:Example, mode=Paper())
```

To start the strategy, use the following command:

```julia
using PaperMode
start!(s)
```

Upon executing this, the following log output is expected:

```julia
┌ Info: Starting strategy ExampleMargin in paper mode!
│
│     throttle: 5 seconds
│     timeframes: 1m(main), 1m(optional), 1m 15m 1h 1d(extras)
│     cash: USDT: 100.0 (on phemex) [100.0]
│     assets: ETH/USDT:USDT, BTC/USDT:USDT, SOL/USDT:USDT
│     margin: Isolated()
└
[ Info: 2023-07-07T04:49:51.051(ExampleMargin@phemex) 0.0/100.0[100.0](USDT), orders: 0/0(+/-) trades: 0/0/0(L/S/Q)
[ Info: 2023-07-07T04:49:56.057(ExampleMargin@phemex) 0.0/100.0[100.0](USDT), orders: 0/0(+/-) trades: 0/0/0(L/S/Q)
```

To run the strategy as a background task:

```julia
start!(s, foreground=false)
```

The logs will be written either to the `s[:logfile]` key of the strategy object, if present, or to the output of the `runlog(s)` command.

# Understanding Paper Mode
When you initiate paper mode, asset prices are monitored in real-time from the exchange. Order execution in Paper Mode is similar to SimMode, albeit the actual price, the trade amount, and the order execution sequence are guided by real-time exchange data.

In detail:
- **Market Orders** are executed by surveying the order book and sweeping available bids/asks. Consequently, the final price and amount reflect the average of all the entries available on the order book.
- **Limit Orders** sweep the order book as well, though only for bids/asks that are below the limit price set for the order. If a Good-Till-Canceled (GTC) order is not entirely filled, a task is generated that continuously monitors the exchange's trade history. Trades that align with the order's limit price are used to fulfill the remainder of the limit order amount.