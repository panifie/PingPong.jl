# Data

The Data module is responsible for the persistent storage and representation of OHLCV (Open, High, Low, Close, Volume) data.

The primary backend is Zarr, which is similar to Feather or Parquet in that it optimizes for columnar data, or more generally, _arrays_. Zarr is simpler and allows for different encoding schemes. It supports compression by default and can be backed by various storage layers, including network-based ones. Compared to NoSQL databases, columnar storage has the drawback of having to read _chunks_ for queries. However, we are almost always interested in time-series data, not scalar values, so the latency loss is negligible.

We wrap a Zarr subtype of `AbstractStore` in a [`PingPong.Data.ZarrInstance`](@ref). The module holds a global `ZarrInstance` at `Data.zi[]`. The default store used relies on LMDB. OHLCV data is organized according to exchanges, pairs, and timeframes ([`PingPong.Data.key_path`](@ref)).

There are several ways to collect data:

## Using the `Scrapers` module
Currently, there is support for Binance and Bybit archives.

```julia
using Scrapers: Scrapers as scr, BinanceData as bn
## Download klines for ETH
bn.binancedownload("eth", market=:data, freq=:monthly, kind=:klines)
## load them
bn.binanceload("eth", market=:data, freq=:monthly, kind=:klines)
## Default market parameter is `:um` (usdm futures)

# show all symbols that can be downloaded
bn.binancesyms(market=:data)
# load/download also accept `quote_currency` to filter by (default `usdt`)
scr.selectsyms(["eth"], bn.binancesyms(market=:data), quote_currency="usdc")
```
!!! warning "Downloads are cached"
    Downloading the same pair path again will only download newer archives.
    If data gets corrupted, pass `reset=true` to redownload it again. 

## Using the `Fetch` module
The `Fetch` module downloads data directly from the exchange using `ccxt`.

```julia
using TimeTicks
using Exchanges
using Fetch: Fetch as fe

exc = getexchange!(:kucoin)
timeframe = "1m"
pairs = ("BTC/USDT", "ETH/USDT")
# Will fetch the last 1000 candles, `to` can also be passed to download a specific range
fe.fetch_ohlcv(exc, timeframe, pairs; from=-1000)
```
Fetching directly from exchanges is not recommended for smaller timeframes since they are heavily rate-limited.
Archives are a better option.

## Using `Watchers`
With the `Watchers` module, you can track live data from exchanges or other data sources and store it locally. 
Implemented are watchers that track OHLCV:

```julia
using Exchanges
using PingPong.Watchers: Watchers as wc, WatchersImpls as wi
exc = getexchange!(:kucoin)

w = wi.ccxt_ohlcv_tickers_watcher(exc;)
wc.start!(w)
```

```julia
>>> w
17-element Watchers.Watcher20{Dict{String, NamedTup...Nothing, Float64}, Vararg{Float64, 7}}}}}
Name: ccxt_ohlcv_ticker
Intervals: 5 seconds(TO), 5 seconds(FE), 6 minutes(FL)
Fetched: 2023-03-07T12:06:18.690 busy: true
Flushed: 2023-03-07T12:04:31.472
Active: true
Attemps: 0
```

As a convention, the `view` property of a watcher shows the processed data. In this case, the candles processed
by the `ohlcv_ticker_watcher` will be stored in a dict.

```julia
>>> w.view
Dict{String, DataFrames.DataFrame} with 220 entries:
  "HOOK/USDT"          => 5×6 DataFrame…
  "ETH/USD:USDC"       => 5×6 DataFrame…
  "PEOPLE/USDT:USDT"   => 5×6 DataFrame…
```

There is another OHLCV watcher based on trades, that tracks only one pair at a time.

``` julia
w = wi.ccxt_ohlcv_watcher(exc, "BTC/USDT:USDT"; timeframe=tf"1m")
w.view
956×6 DataFrame
 Row │ timestamp            open     high     low      close    volume  
     │ DateTime             Float64  Float64  Float64  Float64  Float64 
─────┼──────────────────────────────────────────────────────────────────
...
```

Other implemented watchers are the orderbook watcher, and watchers that parse data feeds from 3rd party APIs.

## Other sources

Assuming you have your own pipeline to fetch candles, you can use the functions [`PingPong.Data.save_ohlcv`](@ref) and [`PingPong.Data.load_ohlcv`](@ref) to manage the data.
To save the data, it is easier if you pass a standard OHLCV dataframe, otherwise you need to provide a `saved_col` argument that indicates the correct column index to use as the `timestamp` column (or use lower-level functions).

```julia
using PingPong
@environment!
@assert da === Data
source_name = "mysource"
pair = "BTC123/USD"
timeframe = "1m"
zi = Data.zi # the global zarr instance, or use your own
mydata = my_custom_data_loader()
da.save_ohlcv(zi, source_name, pair, timeframe, mydata)
```
To load the data back:

```julia
da.load_ohlcv(zi, source_name, pair, timeframe)
```

Data is returned as a `DataFrame` with `open,high,low,close,volume,timestamp` columns.
Since these save/load functions require a timestamp column, they check that the provided index is contiguous, it should not have missing timestamps, according to the subject timeframe. It is possible to disable those checks by passing `check=:none`.

If you want to save other kinds of data, there are the [`PingPong.Data.save_data`](@ref) and [`PingPong.Data.load_data`](@ref) functions. Unlike the ohlcv functions, these functions don't check for contiguity, so it is possible to store sparse data. The data, however, still requires a timestamp column, because data when saved can either be prepend or appended, therefore an index must still be available to maintain order.
While OHLCV data requires a concrete type for storage (default `Float64`) generic data can either be saved with a shared type, or instead serialized. To serialize the data while saving pass the `serialize=true` argument to `save_data`, while to load serialized data pass `serialized=true` to `load_data`.

When loading data from storage, you can directly use the `ZArray` by passing `raw=true` to `load_ohlcv` or `as_z=true` or `with_z=true` to `load_data`. By managing the array directly you can avoid materializing the entire dataset, which is required when dealing with large amounts of data.

## Indexing
The Data module implements dataframe indexing by dates such that you can conveniently access rows by:

```julia
df[dt"2020-01-01", :high] # get the high of the date 2020-01-01
df[dtr"2020-..2021-", [:high, :low]] # get all high and low for the year 2020
after(df, dt"2020-01-01") # get all candles after the date 2020-01-01
before(df, dt"2020-01-01") # get all candles up until the date 2020-01-01
```

With ohlcv data, we can access the timeframe of the series directly from the dataframe by calling `timeframe!(df)`. This will either return the previously set timeframe or infer it from the `timestamp` column. You can set the timeframe by calling e.g. `timeframe!(df, tf"1m")` or `timeframe!!` to overwrite it.

## Caching
`Data.Cache.save_cache` and `Data.Cache.load_cache` can be used to store generic metadata like JSON payloads. The data is saved in the PingPong data directory which is either under the `XDG_CACHE_DIR`[^1] if set or under `$HOME/.cache` by default.

[^1]: Default path might be a scratchspace (from Scratch.jl) in the future
