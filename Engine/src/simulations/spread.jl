using Lang
using TimeTicks
# using ..Strategies
# using ..Collections
using ..Types.Instances
using Statistics: cov, mean
using Data.DFUtils
using Instruments

function rawspread(high::T, low::T, close::T) where {T}
    Δ = high - low
    Δ == 0.0 && return 0.0
    b = (close - low) / Δ
    2.0 * (1.0 - b) * Δ
end
rawspread(c::Candle) = rawspread(c.high, c.low, c.close)
function logspread(high::T, low::T, close::T) where {T<:PricePair}
    # The first price of the pair should precede the second in the chronological order
    lcp = log(close.prev)
    max(
        4.0 *
        abs(lcp - (log(high.prev) + log(low.prev) / 2.0)) *
        abs(lcp - (log(high.this) + log(low.this)) / 2.0),
        0.0,
    )
end
logspread(l2::LastTwo) = logspread(l2.high, l2.low, l2.close)
function sqrtspread(price)
    (maximum(price) - minimum(price)) / (2 * sqrt(length(price)))
end
function coschspread(high, low; window=1440 * 2)
    if window > 0
        high = @view high[(end - window + 1):end]
        low = @view low[(end - window + 1):end]
        @assert length(high) == length(low)
    end
    h2 = maximum(high)
    l2 = minimum(low)
    idx = ((length(high) ÷ 2) + 1):lastindex(high)
    h1 = mean(view(high, idx))
    l1 = mean(view(low, idx))
    γ = log(h2 / l2) / 3.0 - log(h1 / l1) / 6.0
    (2.0 * (ℯ^(γ) - 1.0) / (1.0 + ℯ^(γ)))
end
rollspread(close) = 2 * sqrt(2 * cov(close))

_edgereturns(high::T, low::T) where {T<:AbstractVector} = sum(log.(high / low)^2)
_edgereturns(high, low) = log(high / low)^2
_edgelen(v::AbstractVector) = length(v)
_edgelen(v) = 1
_edgesqrt(v::AbstractVector) = sqrt.(v)
_edgesqrt(v) = sqrt(v)
_edgenop(high::T, low::T) where {T<:AbstractVector} = false
_edgenop(high, low) = high == low

function edgespread(high, low)
    _edgenop(high, low) && return 0.0
    @assert length(high) == length(low)
    diff = high - low
    returns = abs(_edgereturns(high, low))
    n = _edgelen(high)
    ratio = diff / (n * returns)
    a = 2.0 * sqrt(2.0 * π) * ratio
    b = 1.5 * _edgesqrt(diff)
    abs(mean(a - b))
end
function edge2spread(high, low, high_prev, low_prev)
    hl = log(high / low)
    hl_prev = log(high_prev / low_prev)
    diff = hl - hl_prev
    diff == 0 && return 0
    (((hl - hl_prev) / (hl + hl_prev))^2) / 2
end
function abraspread(high, low, close)
    h = log(high)
    l = log(low)
    c = log(close)
    sqrt(2 / π) * abs(c - (h + l) / 2)
end

function opclspread(close_prev, open)
    abs(close_prev - open)
end

@doc """ Spread estimators.
The default estimator is `:opcl` which is simply based on the difference between the previous close and the open price.

!!! warning "Fake OHLCV data"
    Some OHLCV data fakes the open (it duplicates the close), in which case a different estimator should be used since :opcl would always return 0.
    As an alternative `:sqrt` is recommended.

Here is a list of some estimators with (pearson) correlation score againt `:opcl` (with default window)
- `:opcl` (default)
- `:raw` 0.25 (has outliers)
- `:log` 0.18
- `:sqrt` 0.29 (fast)
- `:abra` 0.17
- `:roll` 0.29 (has outliers)
- `:cosch` 0.22
- `:edge` 0.25 (slow)
- `:edge2` -0.03

!!! warning "Performance"
    Most of the estimators that require a window currently are slow because the computation is not performed over a moving window.
"""
spread(args...; kwargs...) = opclspread(args...)
spread(::Val{:log}, args...; kwargs...) = logspread(args...; kwargs...)
spread(::Val{:raw}, args...; kwargs...) = rawspread(args...; kwargs...)
spread(::Val{:sqrt}, args...; kwargs...) = sqrtspread(args...; kwargs...)
spread(::Val{:cosch}, args...; kwargs...) = coschspread(args...; kwargs...)
spread(::Val{:roll}, args...; kwargs...) = rollspread(args...; kwargs...)
spread(::Val{:edge}, args...; kwargs...) = edgespread(args...; kwargs...)
spread(::Val{:edge2}, args...; kwargs...) = edge2spread(args...; kwargs...)
spread(::Val{:abra}, args...; kwargs...) = abraspread(args...; kwargs...)
spread(::Val{:opcl}, args...; kwargs...) = opclspread(args...; kwargs...)

function spreadat(v::Val{:log}, df::AbstractDataFrame, date)
    idx = dateindex(df, date)
    spread(v, (@splatpairs df idx :high :low :close)...)
end

function spreadat(v::Union{Val{:abra},Val{:raw}}, df::AbstractDataFrame, date)
    idx = dateindex(df, date)
    spread(v, df.high[idx], df.low[idx], df.close[idx])
end

function spreadat(v::Val{:opcl}, df::AbstractDataFrame, date; nonzero=false)
    idx = dateindex(df, date)
    s = spread(v, df.close[idx - 1], df.open[idx])
    nonzero || return s
    while s == 0.0
        idx -= 1
        s = spread(v, df.close[idx - 1], df.open[idx])
    end
    return s
end

@views function spreadat(v::Val{:cosch}, df, date; window=5)
    idx = dateindex(df, date)
    high = df.high[(idx - window + 1):idx]
    low = df.low[(idx - window + 1):idx]
    spread(v, high, low; window=0)
end

_closewin(df, date, window) = begin
    idx = dateindex(df, date)
    @view df.close[(idx - window + 1):idx]
end

spreadat(v::Val{:roll}, df, date; window=5) = spread(v, _closewin(df, date, window))
spreadat(v::Val{:sqrt}, df, date; window=5) = spread(v, _closewin(df, date, window))

function spreadat(v::Val{:edge}, df::AbstractDataFrame, date; window=5)
    idx = dateindex(df, date)
    if window > 0
        start = idx - window + 1
        high = df.high[start:idx]
        low = df.low[start:idx]
        spread(v, high, low)
    else
        spread(v, df.high[idx], df.low[idx])
    end
end

function spreadat(v::Val{:edge2}, df::AbstractDataFrame, date)
    idx = dateindex(df, date)
    prev_idx = idx - 1
    spread(v, df.high[idx], df.low[idx], df.high[prev_idx], df.low[prev_idx])
end

@doc "Calc the spread of an asset instance at a specified date.

If date is not provided, the last available date will be considered."
function spreadat(inst::AssetInstance, date::DateTime, v::Val=Val(:raw))
    spreadat(v, inst.ohlcv, date)
end

function spreadat(inst::AssetInstance, v::Val=Val(:raw))
    data = inst.ohlcv
    date = data.timestamp[end]
    spreadat(v, data, date)
end

export spread, spreadat
