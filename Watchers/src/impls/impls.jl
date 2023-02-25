module WatchersImpls
using LazyJSON
using Lang: @define_fromdict!, @lget!, @kget!, fromdict, Option
using TimeTicks
using ..Watchers
import ..Watchers: _fetch!, _init!, _load!, _flush!, _process!, _get, _push!, _pop!
using Data
using Data.DFUtils: appendmax!
using Data.DataFrames
using Processing

using ..CoinGecko: CoinGecko
cg = CoinGecko
using ..CoinPaprika: CoinPaprika
cp = CoinPaprika

include("utils.jl")
include("cg_ticker.jl")
include("cg_derivatives.jl")
include("cp_markets.jl")
include("cp_twitter.jl")
include("ccxt_tickers.jl")
include("ccxt_ohlcv_trades.jl")
include("ccxt_ohlcv_tickers.jl")

end
