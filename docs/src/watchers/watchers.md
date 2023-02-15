# Watchers
A `Watcher` type is an interface over a data feed. There are implementations for some 3d party apis, and exchange OHLCV data construction and order book.

## User interface
To instantiate a watcher call its related function for example `ccxt_ohlcv_watcher` to instantiate a watcher that tracks trades data from an exchange and builds OHLCV candles for the specified timeframe.
On a watcher instance these function are currently available:
- `get`: What you mostly use watchers for. Get the underlying data monitored by the watcher, usually in a processed state (like a `DataFrame`), it defaults to the watcher buffer (which *should* keep data in a raw state).
- `length`: Length of the underlying buffer.
- `last`: Last raw value of the underlying buffer.
- `close`: Stops the watcher and flushes the buffer.
- `isstale`: Should evaluate if the watcher is in a degraded state, e.g. when it can't fetch new data.
- `fetch!`: A watcher runs queries on specified interval, so you should only use `fetch!` when you want to be sure that the watcher has the latest data.
- `flush!`: like `fetch!` the watcher already flushes at predetermined intervals, use this only to ensure flushing in case of shutdown. The watcher *does* call flush on destruction through its finalizer, but it does so asynchronously and doesn't ensure the success of the flush operation.
- `delete!`: deletes the watcher data from the storage backend used by `flush!`.

## Imlementation interface
To implement a custom watcher you have to define the functions such that dispatch happens through the watcher name interpreted as a value `Val{Symbol(my_watcher_name)}`. So a function needs to have a signature like `_fetch!(w::Watcher, ::Val{some_symbol})`.
### Required 
- `_fetch!` whatever fetches the data, like an http request.
- `_get` returns the post processed data, like a `DataFrame`.
### Optional
- `_init!` to perform initialization routines.
- `_load!` to pre-fill the watcher buffer on construction, it is only called once, runs after `_init!`.
- `_flush!` to save the watcher buffer somewhere on periodic intervals and on watcher destruction.
- `_process!` to update the *view* of the raw data, which is what the *get* function should return.

Look in the `Watchers` and `WatchersImpls` modules for helper functions:

```@autodocs
Modules = [Watchers, Watchers.WatchersImpls]
```
