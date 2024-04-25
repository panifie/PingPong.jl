using Processing: TradesOHLCV as tra, cleanup_ohlcv_data, trail!
using Processing: Processing, Pbar, Data
using CSV
using Instruments
using ZipFile: ZipFile as zip
using HTTP
using .Data: zi, zinstance
using .Data.Misc
using CodecZlib: CodecZlib as zlib

using .Misc.TimeTicks
using .Misc.Lang
using .Misc.Lang: @ifdebug, @acquire, splitkws
using .Misc: LittleDict
using .Misc.DocStringExtensions
using .Data.Cache: Cache as ca
using .Data.DFUtils: lastdate, firstdate
using .Data.DataFrames
using .Pbar

@doc "Controls the number of workers used by the Scrapers module to download chunks (1 chunk == 1 request).
See also [`SEM`](@ref)
"
const WORKERS = Ref(4)
@doc "The time frame used by the Scrapers module."
const TF = Ref(tf"1m")
@doc "A samaphore for parallel downloads. Controls how many symbols are downloaded in parallel.
When downloading archives from scratch use more [`WORKERS`](@ref) and smaller `sem_size`, when updating use larer `sem_size` and fewer workers.
"
const SEM = Base.Semaphore(3)

@doc "Default HTTP parameters used by the Scrapers module."
const DEFAULT_HTTP_PARAMS = (; connect_timeout=30)
@doc "Active HTTP parameters used by the Scrapers module."
const HTTP_PARAMS = LittleDict{Symbol, Any}(:connect_timeout => 30)

function _doinit()
    zi[] = zinstance()
end

include("utils.jl")
include("bybit.jl")
include("binance.jl")
