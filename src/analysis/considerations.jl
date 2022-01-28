@doc "Predicates that signal increased chances of success (The opposite of violations)."
module Considerations

using Backtest.Analysis.Violations: mustd, isdcandles, PairData, AbstractDataFrame, DataFrame, std, mean, _score_sum
using Backtest.Analysis: @pairtraits!
using Backtest.Analysis: maptf
using DataFramesMeta

function last_breakout(price, br_lvl; op = >)
    for (n, p) in enumerate(price)
        op(p, br_lvl) && return n
    end
    return 0
end

@doc """Follow through price action.
`min_follow`: Minimum number of upward candles that have to follow after breakout."""
function fthrough(high, low, close; br = mustd, min_follow::Int = 1)
    # use high for finding breakouts
    br_lvl = br(high, low, close)
    br_idx = last_breakout(high, br_lvl)
    if iszero(br_idx) || br_idx === lastindex(high)
        nothing
    else
        @assert min_follow >= 1 "Follow through candles have to be at least 1."
        for i in br_idx+1:br_idx+min_follow
            high[i] >= high[i-1] || return false
        end
        return true
    end
end
fthrough(df::AbstractDataFrame; kwargs...) = fthrough(df.high, df.low, df.close; kwargs...)

function isbuyvol(open, close, volume; threshold = 0.1)
    bv = 0
    dv = 0
    for (o, c, v) in zip(open, close, volume)
        if c > o
            bv += v
        else
            dv += v
        end
    end
    @debug "bv = $bv; dv = $dv"
    bv / dv >= 1 + threshold
end
isbuyvol(df::AbstractDataFrame; kwargs...) = isbuyvol(df.open, df.close, df.volume; kwargs...)

@doc """Tennis ball action, resilient price snapback after a pullback.
`snapack`: The number of candles to consider for snapback action. """
function istennisball(low; snapback = 3, br = x -> mustd(x; op = -))
    low_br_lvl = br(low)
    # low_br_lvl = Main.an.Violations.mustd(low; op=-)
    br_idx = last_breakout(low, low_br_lvl; op = <)
    if iszero(br_idx)
        nothing
    else
        @assert snapback >= 1 "Snapback candles have to be at least 1."
        low[min(lastindex(low), br_idx+snapback)] > low_br_lvl
    end
end

istennisball(df::AbstractDataFrame; kwargs...) = istennisball(df.low; kwargs...)

cweights = (
    ft = 0.2,
    up = 0.1,
    bvol = 0.3
    tball = 0.4
)

@doc "Evaluate trais for a single pair."
function considerations(df::AbstractDataFrame; window=20, window2=50,
                        min_follow::Int=1, vol_thresh=0.1, snapback=3, weights=cweights)
    @debug @assert size(df, 1) > window2

    dfv = @view df[end-window:end, :]
    dfv2 = @view df[end-window2:end, :]

    ft = fthrough(dfv; min_follow)
    up = !isdcandles(dfv2)
    bvol = isbuyvol(dfv2; threshold=vol_thresh)
    tball = istennisball(dfv; snapback)

    vars = (;ft, up, bvol, tball)
    (; vars..., score=_score_sum(vars; weights))
end

_trueish(syms...) = all(isnothing(sym) || sym for sym in syms)

@doc "Evaluate traits for a collection of pairs."
function considerations(mrkts::AbstractDict; all=false, window=20, window2=50, kwargs...)
    local df
    kargs = (;window, window2, kwargs...)
    if valtype(mrkts) <: PairData
        mrkts = Dict(p.name => p.data for p in values(mrkts))
    end
    df = _considerations(mrkts; kargs...)
    all && @rsubset! df begin
        _trueish(:ft, :up, :bvol, :tball)
    end
    sort!(df, :score)
end

function _considerations(mrkts::AbstractDict{String, DataFrame}; kwargs...)
    maxw = max(kwargs[:window], kwargs[:window2])
    [(pair=k, considerations(p; kwargs...)...)
     for (k, p) in mrkts
         if size(p, 1) > maxw] |>
             DataFrame
end

@doc "Evaluate traits on multiple timeframes."
considerations(mrkts, tfs::Vector{String}; kwargs...) = maptf(tfs, mrkts, considerations; kwargs...)

export considerations

end
