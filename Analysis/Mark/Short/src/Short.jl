@doc "Predicates that signal lowered chances of success."
module Short

using Statistics: std, mean
using Data.DataFrames: DataFrame, AbstractDataFrame, index
using Data.DataFramesMeta
using Data: PairData
using Processing: maptf
using Lang

@doc """Breakout level. Mean with std."""
function mustd(price::AbstractVector, args...; op=+)
    op(mean(price), std(price))
end

@views function highout(volume, idx, rt)
    # breakout absolute index is idx
    # retracement absolute index
    rt_idx = idx + rt - 1
    # volume after breakout, until retracement
    r_vol = volume[(idx + 1):rt_idx]
    # volume before breakout, same length as post breakout volume
    l_vol = volume[(idx - length(r_vol) + 1):idx]
    @ifdebug @assert length(l_vol) === length(r_vol) "$(length(l_vol)), $(length(r_vol))"
    sum(r_vol) > sum(l_vol)
end

@doc """
True if series experienced a recent breakout with high volume retracement (Low out, High in).
If breakout is not met, returns `nothing`.
`br`: Breakout rule.
`window`: How far backward to look for breakouts.
`delay`: Delay to look for retracements.
"""
function lowhin(
    high::AbstractVector,
    low::AbstractVector,
    close::AbstractVector,
    volume::AbstractVector;
    br=mustd,
    lastonly=false,
)::Union{Nothing,Int}
    # use high for finding breakouts
    br_lvl = br(high, low, close)
    bos = findall((high .> br_lvl))
    @views if isempty(bos)
        nothing
    elseif lastonly || length(bos) === 1
        idx = last(bos)
        # Find where price first dropped below the breakout (using lows)
        rt = findfirst(low[idx:end] .< br_lvl)
        isnothing(rt) && return nothing
        highout(volume, idx, rt)
    else
        c = 0
        for (n, idx) in enumerate(bos[1:(end - 1)])
            beforenext = bos[n + 1] - 1

            rt = findfirst(low[idx:beforenext] .< br_lvl)
            isnothing(rt) && continue

            c += highout(volume, idx, rt)
        end
        c
    end
end

function lowhin(df::AbstractDataFrame; kwargs...)
    lowhin(df.high, df.low, df.close, df.volume; kwargs...)
end

@views function lowerlows(open, low, close)
    c = 0
    for (n, l) in enumerate(low[2:end])
        c += l < low[n] && open[n] <= close[n]
    end
    c
end

islowerlows(args...; min_lows=3) = lowerlows(args...) > min_lows

function lowerlows(df::AbstractDataFrame; kwargs...)
    lowerlows(df.open, df.low, df.close; kwargs...)
end
function islowerlows(df::AbstractDataFrame; kwargs...)
    islowerlows(df.open, df.low, df.close; kwargs...)
end

dcandles(open, close) = sum(open .>= close)

@doc "Are down candles more than up candles?"
function isdcandles(open, close)
    dd = dcandles(open, close)
    dd >= length(close) - dd
end
isdcandles(df::AbstractDataFrame) = isdcandles(df.open, df.close)

@doc "Is the close below the Average?"
isbelow20(close, last_close) = last_close <= mean(close)
isbelow20(df::AbstractDataFrame) = isbelow20(df.close, df.close[end])

@doc """Is the close below the average with volume above average?
Intended to be used on longer windows in contrast to the volume-less version. """
@views function isbelow50(close, last_close, volume, last_volume)
    last_close <= mean(close) && last_volume > mean(volume)
end
function isbelow50(df::AbstractDataFrame)
    isbelow50(df.close, df.close[end], df.volume, df.volume[end])
end

@doc "Has a full retracement occurred?"
function fullret(open, high, close; gain=0.1)::Union{Nothing,Bool}
    op = open[1]
    hi, hi_idx = findmax(high)
    hi / op < 1.0 + gain && return nothing

    # If the minimum close after the high is below the first open,
    # a full retracement has happened
    minimum(@view(close[hi_idx:end])) <= op
end
fullret(df::AbstractDataFrame; gain=0.1) = fullret(df.open, df.high, df.close; gain)

function _score_sum(nmtup; weights)
    s = 0
    for (k, v) in zip(keys(nmtup), nmtup)
        s += something(v, 0) * weights[k]
    end
    s
end

const vweights = Ref((lowhigh=0.2, llows=0.3, down=0.05, b20=0.15, b50=0.25, retrace=0.05))

function short(
    df::AbstractDataFrame;
    window=20,
    window2=50,
    min_lows=3,
    gain=0.1,
    neg=true,
    weights=vweights[],
)
    @ifdebug @assert size(df, 1) > window2

    dfv = @view df[(end - window):end, :]
    dfv2 = @view df[(end - window2):end, :]
    # Low In High Out
    lowhigh = lowhin(dfv)
    llows = islowerlows(dfv; min_lows)
    down = isdcandles(dfv2)
    b20 = isbelow20(dfv)
    b50 = isbelow50(dfv2)
    retrace = fullret(df; gain)

    vars = (; lowhigh, llows, down, b20, b50, retrace)
    # NOTE: negate the score since short are bad...
    score = _score_sum(vars; weights)
    (; vars..., score=(neg ? -score : score))
end

function short(
    mrkts::AbstractDict; window=20, window2=50, sorted=true, rev=false, kwargs...
)
    local df
    kargs = (; window, window2, kwargs...)
    if valtype(mrkts) <: PairData
        mrkts = Dict(p.name => p.data for p in values(mrkts))
    end
    df = _short(mrkts; kargs...)
    rev && @rsubset! df begin
        isnorz(:lowhigh, :llows, :down, :b20, :b50, :retrace)
    end
    sorted && !isempty(df) && sort!(df, :score)
    df
end

function _short(mrkts::AbstractDict{String,DataFrame}; kwargs...)
    maxw = max(kwargs[:window], kwargs[:window2])
    DataFrame([(pair=k, short(p; kwargs...)...) for (k, p) in mrkts if size(p, 1) > maxw])
end

short(mrkts, tfs::Vector{String}; kwargs...) = maptf(tfs, mrkts, short; kwargs...)

_isnorz(sym) = isnothing(sym) || iszero(sym)
isnorz(syms...) = all(_isnorz(s) for s in syms)

# NOTE: "Good closes and bad closes" is not considered as a metric. It requires assessing
# if the last candles of a window moved too sharply in one direction or the other

@doc "A good short should have high volume, (too) high price change, and dominating red candles."
function find(mrkts::AbstractDict; window=15)
    mvp = []
    for p in mrkts
        b, d = MVP.is_mvp(p; real=false)
        push!(mvp, (p[1], d))
    end
    isshorter = (x, y) -> x[2].v > y[2].v && x[2].p > y[2].p && x[2].m < y[2].m
    sort!(mvp; lt=isshorter)
    mvp
end

export short

end
