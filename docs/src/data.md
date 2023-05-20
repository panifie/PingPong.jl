# Data

The main backend currently is Zarr. Zarr is similar to feather or parquet in that it optimizes to columnar data, or in general _arrays_. However it is simpler, and allows to pick different encoding schemes, and supports compression by default. More over the zarr interface can be backed by different storage layers, that can also be over the network. Compared to no/sql databases columnar storage has the drawback of having to read _chunks_ for queries, but we are almost never are interested in scalar values, we always query a time-series of some sort, so the latency loss is a non issue.

# Scraping

There are different ways to collect data:
## Using the `Scrapers` module
Currently there is support for binance and bybit archives.

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
!! "Downloads are cached"
    downloading the same pair path again will only downloads newer archives
    if data gets corrupted pass `reset=true` to redownload it again. 

## Using the `Fetch` module
The `Fetch` module downloads data directly from the exchange using `ccxt`.

```julia
using TimeTicks
using Exchanges
using Fetch: Fetch as fe

exc = getexchange!(:kucoin)
timeframe = tf"1m"
pairs = ("BTC/USDT", "ETH/USDT")
# Will fetch the last 1000 candles, `to` can also be passed to download a specific range
fe.fetch_candles(exc, timeframe, pairs; from=-1000)
```
Fetching directly from exchanges is not recommended for smaller timeframes since they are heavily rate limited.
Archives are better.

## Using `Watchers`
With the `Watchers` module you can track live data from exchanges or other data sources and store it locally. 
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

As a convention the `view` property of a watcher shows the processed data. In this case the candles processed
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

Other implemented watchers are the orderbook watcher, and watchers that parse data feeds from 3rd party apis.


