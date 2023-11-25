using Processing: TradesOHLCV as tra, cleanup_ohlcv_data, trail!
using Processing: Processing, Pbar, Data
using CSV
using Instruments
using ZipFile: ZipFile as zip
using HTTP
using .Data: zi, zilmdb
using .Data.Misc
using CodecZlib: CodecZlib as zlib

using .Misc.TimeTicks
using .Misc.Lang
using .Misc.Lang: @ifdebug, @acquire, splitkws
using .Misc: LittleDict
using .Data.Cache: Cache as ca
using .Data.DFUtils: lastdate, firstdate
using .Data.DataFrames
using .Pbar

@doc "Controls the number of workers used by the Scrapers module."
const WORKERS = Ref(10)
@doc "The time frame used by the Scrapers module."
const TF = Ref(tf"1m")
@doc "A samaphore for parallel downloads."
const SEM = Base.Semaphore(3)

@doc "Default HTTP parameters used by the Scrapers module."
const DEFAULT_HTTP_PARAMS = (; connect_timeout=30)
@doc "Active HTTP parameters used by the Scrapers module."
const HTTP_PARAMS = LittleDict{Symbol, Any}(:connect_timeout => 30)

function _doinit()
    zi[] = zilmdb()
end

include("utils.jl")
include("bybit.jl")
include("binance.jl")
