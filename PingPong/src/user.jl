@doc "User module, use only to import and export preferred functions inside the repl."

using Processing
using Statistics: mean
using Data.DataFramesMeta
using Data.DataFrames
using Data.DataFrames: index
using Misc: @lev!, @margin!
export @margin!, @lev!

if !isdefined(@__MODULE__, :an)
    const sst = StrategyStats
end

macro setup(exc)
    a = esc(:an)
    m = esc(:mrkts)
    mr = esc(:mrkts_r)
    mvp = esc(:mvp)
    quote
        Misc.Config($exc)
        $a = an
        setexchange!($exc)
        $m = load_ohlcv("15m")
        $mr = @resample($m, "1d"; save=false)
    end
end

export @excfilter, @bbranges, @otime, @setup
export vcons, smvp
export price_ranges, gprofit, cbot, cpek, last_day_roc
