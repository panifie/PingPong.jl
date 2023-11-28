using .Lang
using Instances
using Statistics: cov, mean
using Data.DFUtils
using Instances.Instruments
using .Instruments.Misc
using .Misc.TimeTicks

@doc """ Calculate the skewed spread of a trading asset

$(TYPEDSIGNATURES)

This function computes the skewed spread by first calculating the standard spread and the liquidity over a rolling window. 
It then applies normalization to the liquidity values.
The skewness of the spread is considered useful in determining the volatility and the risk related to a trading asset.
"""
function skewed_spread(high, low, close, volume, wnd, ofs)
    spread = spread(high, low, close)
    # min max liquidity statistics over a rolling window to use for interpolation
    liq = calc_liquidity(volume, close, high, low)
    lix_norm = rolling_norm(liq, wnd, ofs)
end

@doc """ Compute the raw spread of a trading asset

$(TYPEDSIGNATURES)

Calculates the raw spread by subtracting the low price from the high price. 
If the difference is zero, it returns zero. 
Otherwise, it computes the raw spread using the formula `2.0 * (1.0 - b) * Δ`, where `b` is `(close - low) / Δ`.

"""
function rawspread(high::T, low::T, close::T) where {T}
    Δ = high - low
    Δ == 0.0 && return 0.0
    b = (close - low) / Δ
    2.0 * (1.0 - b) * Δ
end
rawspread(c::Candle) = rawspread(c.high, c.low, c.close)
@doc """ Compute the logarithmic spread

$(TYPEDSIGNATURES)

This function calculates the logarithmic spread which captures the difference between the log of high and low prices. 
The chronological order of the prices is important for this calculation. 
The logarithmic spread measures the relative price movement of an asset and is especially useful in volatile markets.

"""
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
@doc """ Compute the square root spread

$(TYPEDSIGNATURES)

This function calculates the square root spread of a price series by subtracting the minimum price from the maximum price and dividing the result by twice the square root of the length of the price series.

"""
function sqrtspread(price)
    (maximum(price) - minimum(price)) / (2 * sqrt(length(price)))
end
@doc """ Calculate the cosh spread

$(TYPEDSIGNATURES)

This function calculates the cosh spread over a specified window of high and low prices.
If the window is greater than 0, it truncates the high and low series to the window length from the end. 
Then, it ensures the length of the high and low series is equal before computing the cosh spread.

"""
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
@doc """ Calculate the roll spread

$(TYPEDSIGNATURES)

This function calculates the roll spread of a close price series.
It computes the roll spread by multiplying twice the square root of twice the covariance of the close prices.

"""
rollspread(close) = 2 * sqrt(2 * cov(close))

_edgereturns(high::T, low::T) where {T<:AbstractVector} = sum(log.(high / low)^2)
_edgereturns(high, low) = log(high / low)^2
_edgelen(v::AbstractVector) = length(v)
_edgelen(v) = 1
_edgesqrt(v::AbstractVector) = sqrt.(v)
_edgesqrt(v) = sqrt(v)
_edgenop(high::T, low::T) where {T<:AbstractVector} = false
_edgenop(high, low) = high == low

@doc """ Compute the edge spread

$(TYPEDSIGNATURES)

This function calculates the edge spread by subtracting the low prices from the high prices.
The edge spread is a measure of the volatility of the asset and is used to assess market risk.

"""
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
@doc """ Compute the edge2 spread

$(TYPEDSIGNATURES)

This function calculates the edge2 spread by taking the difference between the maximum of current and previous high prices and the minimum of current and previous low prices.
The edge2 spread is a measure of the range of price movement and can be used to detect potential market volatility.

"""
function edge2spread(high, low, high_prev, low_prev)
    hl = log(high / low)
    hl_prev = log(high_prev / low_prev)
    diff = hl - hl_prev
    diff == 0 && return 0
    (((hl - hl_prev) / (hl + hl_prev))^2) / 2
end
@doc """ Compute the Abra spread

$(TYPEDSIGNATURES)

This function calculates the Abra spread by taking the difference between the high and low prices and adjusting it with the close price. 
The Abra spread is a measure of the price volatility and can be used to gauge the risk associated with the asset.

"""
function abraspread(high, low, close)
    h = log(high)
    l = log(low)
    c = log(close)
    sqrt(2 / π) * abs(c - (h + l) / 2)
end

@doc """ Compute the open-close spread

$(TYPEDSIGNATURES)

This function calculates the open-close spread by subtracting the previous closing price from the current opening price. 
The open-close spread is a measure of the price gap between two trading sessions and can indicate potential market sentiment changes.

"""
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

function spreadat(v::Val{:log}, df::AbstractDataFrame, idx)
    spread(v, (@splatpairs df idx :high :low :close)...)
end

function spreadat(v::Union{Val{:abra},Val{:raw}}, df::AbstractDataFrame, idx)
    spread(v, df.high[idx], df.low[idx], df.close[idx])
end

function spreadat(v::Val{:opcl}, df::AbstractDataFrame, idx; nonzero=false)
    s = spread(v, df.close[idx - 1], df.open[idx])
    nonzero || return s
    while s == 0.0
        idx -= 1
        s = spread(v, df.close[idx - 1], df.open[idx])
    end
    return s
end

@views function spreadat(v::Val{:cosch}, df, idx; window=5)
    high = df.high[(idx - window + 1):idx]
    low = df.low[(idx - window + 1):idx]
    spread(v, high, low; window=0)
end

_closewin(df, idx, window) = begin
    @view df.close[(idx - window + 1):idx]
end

spreadat(v::Val{:roll}, df, idx; window=5) = spread(v, _closewin(df, idx, window))
spreadat(v::Val{:sqrt}, df, idx; window=5) = spread(v, _closewin(df, idx, window))

function spreadat(v::Val{:edge}, df::AbstractDataFrame, idx; window=5, kwargs...)
    if window > 0
        start = idx - window + 1
        high = df.high[start:idx]
        low = df.low[start:idx]
        spread(v, high, low; kwargs...)
    else
        spread(v, df.high[idx], df.low[idx]; kwargs...)
    end
end

function spreadat(v::Val{:edge2}, df::AbstractDataFrame, idx; kwargs...)
    prev_idx = idx - 1
    spread(v, df.high[idx], df.low[idx], df.high[prev_idx], df.low[prev_idx]; kwargs...)
end

function spreadat(inst::AssetInstance, idx, v::Val=Val(:opcl); kwargs...)
    @deassert ohlcv(inst).volume[idx] > 0
    spreadat(v, ohlcv(inst), idx; kwargs...)
end

@doc """ Compute the open-close spread for a specific asset instance at a given date

$(TYPEDSIGNATURES)

This function calculates the open-close spread for a specific asset instance at a given date.
The open-close spread is a measure of the price gap between two trading sessions for the specified asset.
The function uses the value of the open and close prices at the given date.

"""
function spreadat(inst::AssetInstance, date::DateTime, v::Val=Val(:opcl); kwargs...)
    df = ohlcv(inst)
    idx = dateindex(df, date)
    spreadat(v, df, idx; kwargs...)
end

@doc """ Compute the open-close spread for a specific asset instance

$(TYPEDSIGNATURES)

Calculates the open-close spread for a specific asset instance.
The open-close spread is a measure of the price gap between two trading sessions for the specified asset.
This function uses the current date's open and close prices to compute the spread.

"""
function spreadat(inst::AssetInstance, v::Val=Val(:opcl); kwargs...)
    df = ohlcv(inst)
    date = df.timestamp[end]
    idx = dateindex(df, date)
    spreadat(v, df, idx; kwargs...)
end

@doc """ Check if open-close prices are fake

$(TYPEDSIGNATURES)

This function checks if the open and close prices in a given data frame are fake. 
It determines this by checking if the open price equals the close price for all rows in the data frame. 
If they are equal, it returns `true`, indicating fake open-close prices.

"""
function isfakeoc(df::AbstractDataFrame)
    open, close = df.open, df.close
    @inbounds for i in 2:lastindex(df, 1)
        open[i] != close[i - 1] && return false
    end
    true
end
isfakeoc(ai::AssetInstance) = isfakeoc(ohlcv(ai))

export spread, spreadat, isfakeoc
