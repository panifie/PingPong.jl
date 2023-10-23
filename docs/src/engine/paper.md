# Running in paper mode
To construct a strategy in paper mode you can specify the default mode in the `user/pingpong.toml` file, or in the `Project.toml` file of your strategy project, or by passing the mode as a keyword argument:

``` toml
[Example]
mode = "Paper"
```

``` julia
using Strategies
s = strategy(:Example, mode=Paper())
```

Start the strategy:

``` julia
using PaperMode
start!(s)
```

Expect logging output:

``` julia
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

Running the strategy as a task

``` julia
start!(s, foreground=false)
```

Logs will be written either to the strategy `s[:logfile]` key if present or the output of `runlog(s)`.

# How paper mode works
When you start paper mode asset prices are monitored in real time from the exchange. Orders execution is similar to SimMode, but the actual price and the amount trade and the orders execution sequence is dependent on the exchange data. 

- *Market orders* are executed by looking at the orderbook, and sweeping the bids/asks available on it, the final price and amount is therefore the average of all the orderbook entries available on the orderbook.
- *Limit orders* also sweep the orderbook, but only for the bids/asks that fall below the limit price of the order. If the order is not yet fully filled (and is a GTC order) a task is spawned that constantly watches _the trades history_ from the exchange. Trades that fall within the order limit price will be used to fill the remaining limit order amount. 
