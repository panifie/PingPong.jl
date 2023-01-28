@doc "User module, use only to import and export preferred functions inside the repl."

using DataFrames
using DataFrames: index
using DataFramesMeta
using LegibleLambdas
using Misc: @lev!, @margin!
using Processing
using Statistics: mean
export @margin!, @lev!

if !isdefined(@__MODULE__, :an)
    const an = Analysis
end

macro setup(exc)
    a = esc(:an)
    m = esc(:mrkts)
    mr = esc(:mrkts_r)
    mvp = esc(:mvp)
    quote
        Misc.loadconfig($exc)
        $a = an
        setexchange!($exc)
        $m = load_ohlcv("15m")
        $mr = @resample($m, "1d"; save=false)
    end
end

export @excfilter,
    price_ranges, @bbranges, vcons, gprofit, smvp, cbot, cpek, @otime, @setup, last_day_roc
