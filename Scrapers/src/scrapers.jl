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
using .Data.Cache: Cache as ca
using .Data.DFUtils: lastdate, firstdate
using .Data.DataFrames
using .Pbar

const WORKERS = Ref(10)
const TF = Ref(tf"1m")
const SEM = Base.Semaphore(3)

function _doinit()
    zi[] = zilmdb()
end

include("utils.jl")
include("bybit.jl")
include("binance.jl")
