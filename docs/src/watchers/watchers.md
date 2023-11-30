# Watchers

A `Watcher` type serves as an interface over a data feed. Implementations are available for certain third-party APIs, exchange OHLCV (Open, High, Low, Close, Volume) data construction, and order books.

## User Interface

To instantiate a watcher, call its related function. For example, `ccxt_ohlcv_watcher` can be used to instantiate a watcher that tracks trade data from an exchange and builds OHLCV candles for the specified timeframe. 

A watcher instance provides the following functions:

- `get`: Primarily used to retrieve the underlying data monitored by the watcher, usually in a processed state (like a `DataFrame`). It defaults to the watcher buffer (which *should* keep data in a raw state).
- `length`: Returns the length of the underlying buffer.
- `last`: Returns the last raw value of the underlying buffer.
- `close`: Stops the watcher and flushes the buffer.
- `isstale`: Evaluates if the watcher is in a degraded state, e.g., when it can't fetch new data.
- `fetch!`: A watcher runs queries at specified intervals, so you should only use `fetch!` when you want to ensure that the watcher has the latest data.
- `flush!`: Like `fetch!`, the watcher already flushes at predetermined intervals. Use this only to ensure flushing in case of shutdown. The watcher *does* call flush on destruction through its finalizer, but it does so asynchronously and doesn't ensure the success of the flush operation.
- `delete!`: Deletes the watcher data from the storage backend used by `flush!` (and empties the buffer).
- `deleteat!`: Deletes the watcher data within a date range (and empties the buffer).
- `push!`: Adds an element to the elements the watcher subscribes to (if any).
- `pop!`: Opposite of `push!`.
- `stop`: Stops the watcher.
- `start`: Restarts the watcher.

## Implementation Interface

To implement a custom watcher, you need to define functions such that dispatch happens through the watcher name interpreted as a value `Val{Symbol(my_watcher_name)}`. So a function needs to have a signature like `_fetch!(w::Watcher, ::Val{some_symbol})`.

### Required 
- `_fetch!`: Fetches the data, like an HTTP request.
- `_get`: Returns the post-processed data, like a `DataFrame`.

### Optional
- `_init!`: Performs initialization routines.
- `_load!`: Pre-fills the watcher buffer on construction. It is only called once and runs after `_init!`.
- `_flush!`: Saves the watcher buffer somewhere on periodic intervals and on watcher destruction.
- `_process!`: Updates the *view* of the raw data, which is what the *get* function should return.
- `_delete!`: Deletes *all* the storage data of the watcher.
- `_deleteat!`: Deletes the storage data of the watcher within a date range `(from, to)`.
- `_push!`: Watchers might manage a list of things to track (like `Asset` symbols).
- `_pop!`: Inverse of `_push!`.
- `_start`: Executed before starting the timer.
- `_stop`: Executed after stopping the timer.

Refer to the `Watchers` and `WatchersImpls` modules for helper functions.

Watchers are heavy data structures, try to not use many of them, or join multiple jobs into fewer watchers. If you need an high number of multiple asynchronous fetchers rely instead on tasks (`Task`) or consider using [`Rocket.jl`](https://github.com/biaslab/Rocket.jl).

### API
```@autodocs; canonical=false
Modules = [Watchers, Watchers.WatchersImpls]
```
