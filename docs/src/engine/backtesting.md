# Running a backtest
To run a backtest you construct a strategy and then call `backtest!` on it.
- The strategy loads by default a config file located in `PingPong.jl/user/config.toml`
- The config defines the strategy file under `include_file` key in the `[Example]` section

```toml
[Example]
include_file = "strategies/Example.jl"
```

- The strategy file `Example.jl` defines the `Example` module

```julia
module Example
ping!(s::Strategy, ts, ctx) = pong!(...)
end
```


!!! info "Backtesting"
    It is based on [some assumptions](./engine_notes.md)

```julia
using Engine.Strategies
using Engine.Executors: SimMode as bt
s = strategy(:Example)
# Load data in the strategy universe (you need to already have it)
fill!(s) # or stub!(s.universe, datadict)
# backtest the strategy within the period available from the loaded data.
bt.backtest!(s)
# Lets see how we fared:
display(s)
## output
Name: Example
Config: 10.0(USDT)(Base Size), 100.0(USDT)(Initial Cash)
Universe: 3 instances, 1 exchanges
Holdings: assets(trades): 2(977), min BTC: 23.13(USDT), max XMR: 79.611(USDT)
Pending buys: 3
Pending sells: 0
USDT: 32.593 (Cash)
USDT: 156.455 (Total)
```
Our backtest says that our strategy...
- Operated on 3 assets (instances)
- Executed 977 trades
- Starting from 100 USDT it finished with 32 USDT in cash, and 156 USDT worth of assets
- The assets at the end with the minimum value was BTC and the one with the maximum value was XMR.
- At the end there were 3 left open buy orders and no open sell orders.

# Limit Orders
To make a limit order within your strategy you call `pong!` just like any call to the executor. The arguments:

```julia
trade = pong!(s, LimitOrder{Buy}, ai; price, amount, date=ts)
```

Where `s` is your `Strategy{Sim, ...}` instance, `ai` is the `AssetInstance` which the order refers to (it should be one present in your `s.universe`) amount is the quantity in base currency and date should be the one fed to the `ping!` function, which during backtesting would be the current timestamp being evaluated, and during now a recent timestamp. If you look at the example strategy `ts` is _current_ and `ats` _available_. The available timestamp `ats` is the one that matches the last candle that doesn't give you forward knowledge. The `date` given to the order call (`pong!`) must be always the _current_ timestamp.

A limit order call might return a trade if the order was queued correctly. If the trade hasn't completed the order, the order is queued in `s.orders[ai]`. If `isnothing(trade)` is `true`it means the order failed, and was not scheduled, this can happen if the cost of the trade did not meet the asset limits, or there wasn't enough commitable cash. If instead `ismissing(trade)` is `true` it means that the order was scheduled, but that no trade has yet been performed. In backtesting this happen if the price of the order is too low(buy) or too high(sell) for the current candle high/low prices.

At each iteration we need to check if pending orders are fullfilled, therefore we call:
```julia
pong!(s, ts, UpdateOrders())
```
Remember that we always give the _current_ time. Also if you look at the example strategy, the call is executed
right at the beginning of the `ping!` function. `UpdateOrder` should always be called exactly at the beginning and not anywhere else, otherwise during backtesting an order would be executed twice on the same timestamp. This might be made implicit in future version.
