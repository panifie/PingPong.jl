@doc "Predicates that signal lowered chances of success."
module Violations

using Statistics: std, mean
using DataFrames: DataFrame, AbstractDataFrame
using Backtest.Misc: PairData

@doc """ Breakout level. Mean plus std. """
mustd(high, _, _) = std(high) + mean(high)

@views function highout(volume, idx, rt)
    # breakout absolute index is idx
    # retracement absolute index
    rt_idx = idx + rt - 1
    # volume after breakout, until retracement
    r_vol = volume[idx+1:rt_idx]
    # volume before breakout, same length as post breakout volume
    l_vol = volume[idx-length(r_vol)+1:idx]
    @debug @assert length(l_vol) === length(r_vol) "$(length(l_vol)), $(length(r_vol))"
    sum(r_vol) > sum(l_vol)
end

@doc """
True if series experienced a recent breakout with high volume retracement (Low out, High in).
If breakout is not met, returns `nothing`.
`br`: Breakout rule.
`window`: How far backward to look for breakouts.
`delay`: Delay to look for retracements.
"""
function lowhin(high::AbstractVector, low::AbstractVector,
                close::AbstractVector, volume::AbstractVector;
                br = mustd, lastonly=false)::Union{Nothing, Int}
    # use high for finding breakouts
    br_lvl = br(high, low, close)
    bos = (high .> br_lvl) |> findall
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
        for (n, idx) in enumerate(bos[1:end-1])
            beforenext = bos[n+1] - 1

            rt = findfirst(low[idx:beforenext] .< br_lvl)
            isnothing(rt) && continue

            c += highout(volume, idx, rt)
        end
        c
    end
end

lowhin(df::AbstractDataFrame; kwargs...) = lowhin(df.high, df.low, df.close, df.volume; kwargs...)

@views function lowerlows(open, low, close)
    c = 0
    for (n, l) in enumerate(low[2:end])
        c += l < low[n] && open[n] <= close[n]
    end
    c
end

islowerlows(args...; min_lows=3) = lowerlows(args...) > min_lows

lowerlows(df::AbstractDataFrame; kwargs...) = lowerlows(df.open, df.low, df.close; kwargs...)
islowerlows(df::AbstractDataFrame; kwargs...) = islowerlows(df.open, df.low, df.close; kwargs...)

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
    last_close <= mean(close) &&
        last_volume > mean(volume)
end
isbelow50(df::AbstractDataFrame) = isbelow50(df.close, df.close[end], df.volume, df.volume[end])

@doc "Has a full retracement occurred?"
function fullret(open, high, close; gain=0.1)::Union{Nothing, Bool}
    op = open[1]
    hi, hi_idx = findmax(high)
    hi / op < 1. + gain && return nothing

    # If the minimum close after the high is below the first open,
    # a full retracement has happened
    minimum(@view(close[hi_idx:end])) <= op
end
fullret(df::AbstractDataFrame; gain=0.1) = fullret(df.open, df.high, df.close; gain)

function violations(df::AbstractDataFrame; window=20, window2=50, min_lows=3, gain=0.1)
    dfv = @view df[end-window:end, :]
    dfv2 = @view df[end-window2:end, :]
    # Low In High Out
    lowhigh = lowhin(dfv)
    llows = islowerlows(dfv; min_lows)
    down = isdcandles(dfv2)
    b20 = isbelow20(dfv)
    b50 = isbelow50(dfv2)
    retrace = fullret(df; gain)
    (;lowhigh, llows, down, b20, b50, retrace)
end

function violations(mrkts::AbstractDict; kwargs...)
    [(pair=p.name, violations(p.data; kwargs...)...) for (_, p) in mrkts] |>
        DataFrame
end

# NOTE: "Good closes and bad closes" is not considered as a metric. It requires assessing
# if the last candles of a window moved too sharply in one direction or the other

end
