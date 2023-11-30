# Running in Live Mode

A strategy in live mode operates against the exchange API defined by the strategy. To construct the strategy, use the same methods as in [paper mode](./paper.md).

```julia
using Strategies
s = strategy(:Example, mode=Live(), sandbox=false) # The 'sandbox' parameter is passed to the strategy `ping!(::Type, ::Any, ::LoadStrategy)` function
start!(s, foreground=true)
```

## How Live Mode Works
When you start live mode, `pong!` functions are forwarded to the exchange API to fulfill the request. We set up background tasks to ensure events update the local state in a timely manner. Specifically, we run:

- A `Watcher` to monitor the balance. This runs in both spot (`NoMarginStrategy`) and derivatives (`MarginStrategy`). In the case of spot, the balance updates both the cash of the strategy's main currency and all the currencies in the strategy universe. For derivatives, it is used only to update the main currency.
- A `Watcher` to monitor positions when margin is used (`MarginStrategy`). The number of contracts of the open position represents the cash of the long/short `Position` in the `AssetInstance` (`MarginInstance`). This means that *non-zero balances* of a currency other than the strategy's main currency *won't be considered*.
- A long-running task that monitors all the order events of an asset. The task starts when a new order is requested and stops if there haven't been orders open for a while for the subject asset.
- A long-running task that monitors all trade events of an asset. This task starts and stops along with the order background task.

Similar to other modes, the return value of a `pong!` function for creating an order will be:

- A `Trade` if a trade event was observed shortly after the order creation.
- `missing` if the order was successfully created but not immediately executed.
- `nothing` if the order failed to be created, either because of local checks (e.g., not enough cash) or some other exchange error (e.g., API timeout).

## Timeouts
If you don't want to wait for the order processing, you can pass a custom `waitfor` parameter which limits the amount of time we wait for API responses.

```julia
pong!(s, ai, MarketOrder{Buy}; synced=false, waitfor=Second(0)) # don't wait
```
The `synced=true` flag is a last-ditch attempt that _force fetches_ updates from the exchange if no new events have been observed by the background tasks after the waiting period expires (default is `true`).

The local trades history might diverge from the data sourced from the exchange because not all exchanges support endpoints for fetching trades history or events, therefore trades are emulated from diffing order updates.

The local state is *not persisted*. Nothing is saved or loaded from storage. Instead, we sync the most recent history of orders with their respective trades when the strategy starts running. (This behavior might change in the future if need arises.)
