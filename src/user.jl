@doc "User module, use only to import and export preferred functions inside the repl."

using DataFrames
using LegibleLambdas
using DataFrames: index
using DataFramesMeta
using Misc: @margin!, @lev!
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
        an.@pairtraits!
        $m = load_pairs("15m")
        $mr = an.resample($m, "1d"; save = false)
    end
end


export @excfilter,
    price_ranges, @bbranges, vcons, gprofit, smvp, cbot, cpek, @otime, @setup, last_day_roc
