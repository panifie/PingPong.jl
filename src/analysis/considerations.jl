@doc "Predicates that signal increased chances of success (The opposite of violations)."
module Considerations

using Backtest.Analysis.Violations: mustd, isdcandles, PairData, AbstractDataFrame, DataFrame, std, mean, _score_sum
using Backtest.Analysis: @pairtraits!, maptf, slopeangle
using Backtest.Misc: @as_dfdict
using Backtest.Data: @to_mat
using DataFramesMeta
using Backtest.Analysis.MVP
using StatsBase: transform!, transform, fit, ZScoreTransform, UnitRangeTransform
using StatsModels: lag
import Indicators
const ind = Indicators

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
`snapback`: The number of candles to consider for snapback action. """
function istennisball(low; snapback = 3, br = x -> mustd(x; op = -))
    low_br_lvl = br(low)
    # low_br_lvl = Main.an.Violations.mustd(low; op=-)
    br_idx = last_breakout(low, low_br_lvl; op = <)
    if iszero(br_idx)
        nothing
    else
        @assert snapback >= 1 "Snapback candles have to be at least 1."
        low[min(lastindex(low), br_idx + snapback)] > low_br_lvl
    end
end

istennisball(df::AbstractDataFrame; kwargs...) = istennisball(df.low; kwargs...)

# STAGE2

@doc "Since relative strength computes the score for the whole set, it is useful to cache it when querying elements from the same set."
const rs_cache = Ref(hash(0) => DataFrame())

normalize!(arr; unit = false, dims = ndims(arr)) = _normalize(arr; unit, dims, copy = true)
normalize(arr; unit = false, dims = ndims(arr)) = _normalize(arr; unit, dims, copy = false)

function _normalize(arr::AbstractArray; unit = false, dims = ndims(arr), copy = false)
    t = copy ? transform! : transform
    fit(unit ? ZScoreTransform : UnitRangeTransform, arr; dims) |>
    x -> t(x, arr)
end

@doc """
Given a collection of price timeseries (1D), calculate the _relative strength_ of each series
as the summation of the rate of change at each timestep _t_.
"""
@views function relative_strength(price_mat::Matrix, vol_mat::Matrix; norm_roc = false, norm_str = false)
    @assert size(price_mat) == size(vol_mat)
    # normalize volume pair historically (not across all pairs).
    norm_vol = normalize(vol_mat[2:end, :]; unit = true, dims = 1)
    # Compute rate of change,
    roc = price_mat[2:end, :] ./ price_mat[1:end-1, :] .- 1
    # normalizing across all pairs (helps smoothing)
    norm_roc && normalize!(roc; dims = 2)
    # # weighting by the historically normalized pair volume
    roc .*= norm_vol
    s = sum(roc; dims = 1)
    s = reshape(s, size(s, 2))
    norm_str && normalize!(s; unit = true)
    s
end

function mrkts_key(mrkts::AbstractDict; kwargs...)
    p_1 = Set(keys(mrkts))
    p_2 = Set([size(p, 1) for p in values(mrkts)])
    hash((p_1, p_2, kwargs...))
end

@doc """Computes the relative strength of a collection (dict) of pairs. Returning the queried one, and the rest.
`sorted`: Sort the matrix of all relative strengths.
`norm_roc`: Smooths the ranking by normalizing the rate of change at each candle.
`norm_str`: Normalizes the relative strength between 0 and 1.
"""
function relative_strength(pair::AbstractString, mrkts::AbstractDict; sorted = true, norm_roc = false, norm_str = false)
    @assert pair ∈ keys(mrkts) "Pair not present in data dict."
    mk = mrkts_key(mrkts; sorted, norm_roc, norm_str)
    local df
    if rs_cache[][1] === mk
        df = rs_cache[][2]
    else
        @as_dfdict mrkts
        price_mat, vol_mat, pairs = pair_matrix(mrkts)
        rs = relative_strength(price_mat, vol_mat; norm_roc, norm_str)
        rs = hcat(pairs, rs)
        df = DataFrame(rs, [:pair, :rs])
        sorted && sort!(df, :rs)
        rs_cache[] = mk => df
    end
    (df[firststring(pair, df.pair), :rs], df)
end

function firststring(str, arr)
    for (n, a) in enumerate(arr)
        a === str && return n
    end
end

@doc "Given a dict of dataframes (ohlcv) returns a tuple of matrices, where high and volume are respectively concatenated."
@views function pair_matrix(mrkts::AbstractDict)
    order = Array{String}(undef, length(mrkts))

    min_len = typemax(Int)
    for (n, (k, p)) in enumerate(mrkts)
        order[n] = k
        min_len = min(min_len, size(p, 1))
    end
    ([mrkts[p].high[end-min_len+1:end] |> copy
      for p in order] |> catmarkets,
        [mrkts[p].volume[end-min_len+1:end] |> copy
         for p in order] |> catmarkets,
        order)
end

# speedup concatenation
catmarkets(mrkts::Vector) = reduce(hcat, mrkts)

s2_weights = (
    isabove = 1,
    isabove2 = 1,
    is_trending = 1,
    isaboveyear = 1,
    isclosehigh = 1,
    isabove50 = 1,
    outofbase = 1,
    rel_str = 1
)

@doc """
Stage 2 template.
`base°` is the maximum angle allowed for a pattern to be considered a base (above which would be uptrending).
`baseσ` is the window considered at the last step, for regressing the base formation.
"""
@views function stage2(pair::AbstractString,
    high::AbstractVector,
    low::AbstractVector,
    close::AbstractVector,
    mrkts::AbstractDict;
    base° = 5, baseσ = 15, norm_roc = false)
    @assert length(close) > 365 "Stage 2 indicator needs at least 365 candles."
    price = close[end]
    μ150 = mean(close[end-150+1:end])
    μ200 = mean(close[end-200+1:end])
    isabove = price > μ150 && price > μ200
    μ50 = mean(close[end-50+1:end])
    isabove2 = μ50 > μ150 && μ50 > μ200
    ma200 = ind.sma(close[end-230-1:end]; n = 200)[end-30+1:end]
    is_trending = (ma200[2:end] .> ma200[1:end-1]) |> all
    year_low = low[end-364-1:end]
    isaboveyear = price > minimum(year_low) * 1.25
    year_high = high[end-364-1:end]
    isclosehigh = price > maximum(year_high) * 0.75
    days50 = close[end-50+1:end]
    μ50 = mean(days50)
    isabove50 = price > μ50
    outofbase = (slopeangle(days50; n = baseσ)[baseσ+1:end] .< base°) |> all
    rel_str = relative_strength(pair, mrkts; norm_str = true, norm_roc)[1] > 0.8
    vars = (; isabove, isabove2, is_trending, isaboveyear, isclosehigh, isabove50, outofbase, rel_str)
    (;vars..., score=_score_sum(vars; weights = s2_weights))
end

function stage2(mrkts::AbstractDict; sorted = true, kwargs...)
    @as_dfdict mrkts
    df = _stage2(mrkts; kwargs...)
    sorted && sort!(df, :score)
    df
end

function _stage2(mrkts::AbstractDict{String,DataFrame}; kwargs...)
    for (k, p) in mrkts
        size(p, 1) > 365 || delete!(mrkts, k)
    end
    [(pair = k,
        stage2(k, p.high, p.low, p.close, mrkts; kwargs...)...)
     for (k, p) in mrkts
     if size(p, 1) > 365] |> DataFrame
end

stage2(mrkts, tfs::Vector{String}; kwargs...) = maptf(tfs, mrkts, stage2; kwargs...)

# /STAGE2

cweights = (
    ft = 0.15,
    up = 0.05,
    bvol = 0.25,
    tball = 0.3,
    mvp = 0.25
)

@doc "Evaluate trais for a single pair."
function considerations(df::AbstractDataFrame; window = 20, window2 = 50,
    min_follow::Int = 1, vol_thresh = 0.1, snapback = 3, weights = cweights, mvpargs = (;))
    @debug @assert size(df, 1) > window2

    dfv = @view df[end-window:end, :]
    dfv2 = @view df[end-window2:end, :]

    ft = fthrough(dfv; min_follow)
    up = !isdcandles(dfv2)
    bvol = isbuyvol(dfv2; threshold = vol_thresh)
    tball = istennisball(dfv; snapback)
    mvp = is_mvp(dfv; mvpargs..., real = false)[1]

    vars = (; ft, up, bvol, tball, mvp)
    (; vars..., score = _score_sum(vars; weights))
end

_trueish(syms...) = all(isnothing(sym) || sym for sym in syms)

@doc "Evaluate traits for a collection of pairs."
function considerations(mrkts::AbstractDict; all = false, window = 20, window2 = 50, kwargs...)
    local df
    kargs = (; window, window2, kwargs...)
    if valtype(mrkts) <: PairData
        mrkts = Dict(p.name => p.data for p in values(mrkts))
    end
    df = _considerations(mrkts; kargs...)
    all && @rsubset! df begin
        _trueish(:ft, :up, :bvol, :tball)
    end
    sort!(df, :score)
end

function _considerations(mrkts::AbstractDict{String,DataFrame}; kwargs...)
    maxw = max(kwargs[:window], kwargs[:window2])
    [(pair = k, considerations(p; kwargs...)...)
     for (k, p) in mrkts
     if size(p, 1) > maxw] |>
    DataFrame
end

@doc "Evaluate traits on multiple timeframes."
considerations(mrkts, tfs::Vector{String}; kwargs...) = maptf(tfs, mrkts, considerations; kwargs...)

export considerations

end
