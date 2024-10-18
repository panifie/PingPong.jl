module WatchersImpls
using ..Lang: @lget!, @kget!, fromdict, Option, @k_str
using ..Lang: @statickeys!, @setkey!
using ..TimeTicks
using ..Misc
using ..Watchers
import ..Watchers:
    _fetch!,
    _init!,
    _load!,
    _flush!,
    _process!,
    _get,
    _push!,
    _pop!,
    _start!,
    _stop!,
    _delete!
using ..Data
using ..Data.DFUtils: appendmax!, prependmax!, pushmax!
using ..Data.DataFrames
using ..Fetch.Processing
using Base: Semaphore

using ..CoinGecko: CoinGecko as cg
using ..CoinPaprika: CoinPaprika as cp

# TODO replace _function wrappers with statickeys syntax
@statickeys! begin
    default_view
    timeframe
    n_jobs
    sem
    ids
    key
    status
    logfile
    last_processed
    issandbox
    process_tasks
    excparams
    excaccount
end

include("utils.jl")
include("caching.jl")
include("cg_ticker.jl")
include("cg_derivatives.jl")
include("cp_markets.jl")
include("cp_twitter.jl")
include("ccxt_tickers.jl")
include("ccxt_ohlcv_trades.jl")
include("ccxt_ohlcv_tickers.jl")
include("ccxt_ohlcv_candles.jl")
include("ccxt_orderbook.jl")

end
