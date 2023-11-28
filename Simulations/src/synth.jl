using Data: ohlcvtuple, to_ohlcv, df!
using Processing: Processing, resample
using Random: rand
using Base: DEFAULT_STABLE
using .Misc: config, FUNDING_PERIOD
using .Lang: @deassert
using Statistics: mean, median
using Data.DataFrames: groupby, combine, DataFrame, metadata!, metadatakeys
import Data: stub!

const DEFAULT_DATE = dt"2020-01-01"

@doc """ Generate a synthetic candlestick 

$(TYPEDSIGNATURES)

This function generates a synthetic candlestick data point for a given timestamp.
The synthetic data point includes a synthetic price and volume at the specified timestamp.
The synthetic price is generated based on a seed price, a price update factor, and a price boundary.
Similarly, the synthetic volume is generated based on a seed volume, a volume update factor, and a volume boundary.

"""
function synthcandle(
    ts::DateTime,
    seed_price::Real,
    seed_vol::Real;
    u_price::Real,
    u_vol::Real,
    bound_price::Real,
    bound_vol::Real,
)
    open = let step = rand((-bound_price):u_price:bound_price)
        m = seed_price + step
        m <= 0.0 ? seed_price : m
    end
    high = let step = rand(0:u_price:bound_price)
        open + step
    end
    low = let step = rand(0:u_price:bound_price), l = open - step
        l <= 0.0 ? open : l
    end
    close = let step = rand((-bound_price):u_price:bound_price)
        max(u_price, open + step * (high - low))
    end
    volume = let step = rand((-bound_vol):u_vol:bound_vol)
        m = seed_vol * (low / high) + step
        m <= 0.0 ? abs(step) : m
    end
    @deassert all(v > 0.0 for v in (open, high, low, close)) && volume >= 0.0
    (ts, open, high, low, close, volume)
end

@doc """ Generate a synthetic OHLCV dataset

$(TYPEDSIGNATURES)

This function generates a synthetic OHLCV (Open, High, Low, Close, Volume) dataset for a specified length.
The synthetic data is generated based on a seed price, a seed volume, a price volatility factor, a volume volatility factor, a price update factor, and a volume update factor.
The time frame and start date for the synthetic data can also be specified.

"""
function synthohlcv(
    len=1000;
    tf=tf"1m",
    seed_price=100.0,
    seed_vol=seed_price * 10.0,
    vt_price=3.0,
    vt_vol=3.0,
    u_price=seed_price * 0.01,
    u_vol=seed_vol * 0.5,
    start_date=DEFAULT_DATE,
)
    ans = ohlcvtuple()
    bound_price = u_price * vt_price
    bound_vol = u_vol * vt_vol
    c = synthcandle(
        start_date, seed_price, seed_vol; u_price, u_vol, bound_price, bound_vol
    )
    push!(ans, c)
    ts = start_date + tf
    open = c[5]
    vol = c[6]
    for _ in 1:len
        c = synthcandle(ts, open, vol; u_price, u_vol, bound_price, bound_vol)
        push!(ans, c)
        open = c[5]
        vol = c[6]
        ts += tf
    end
    ans
end

@doc """ Set or append a value to a dictionary

$(TYPEDSIGNATURES)

This function sets a value for a key in a dictionary, or appends the value to the existing values for the key if the key already exists in the dictionary. 
If the key does not exist in the dictionary, it is added with the specified value.

"""
_setorappend(d::AbstractDict, k, v) = begin
    prev = get(d, k, nothing)
    if isnothing(prev)
        d[k] = v
    else
        append!(prev, v)
    end
end

@doc """ Stub an asset instance with synthetic data

$(TYPEDSIGNATURES)

This function stubs an asset instance with synthetic data for a specified length and time frame.
The synthetic data is generated based on a seed price, a seed volume, a price volatility factor, and a volume volatility factor.
The start date for the synthetic data can also be specified.
This function is useful for testing and prototyping purposes when actual market data is not available or not necessary.

"""
function stub!(
    ai::AssetInstance,
    len=1000,
    tfs::Vector{TimeFrame}=collect(keys(ai.data));
    seed_price=100.0,
    seed_vol=1000.0,
    vt_price=3.0,
    vt_vol=500.0,
    start_date=DEFAULT_DATE,
)
    isempty(tfs) && (tfs = config.timeframes)
    sort!(tfs)
    empty!(ai.data)
    min_tf = first(tfs)
    ohlcv =
        synthohlcv(len; tf=min_tf, vt_price, vt_vol, seed_price, seed_vol, start_date) |>
        to_ohlcv
    _setorappend(ai.data, min_tf, ohlcv)
    if length(tfs) > 1
        for t in tfs[2:end]
            _setorappend(ai.data, t, resample(ohlcv, min_tf, t))
        end
    end
end

@doc """Hard coded EMA with n=6 and alpha=2/7.

$(TYPEDSIGNATURES)

Can be used as an approximation of the mark price for perpetual contracts,
where `prices` is a vector of `1m` candles.
"""
@views _price_ema(prices, idx) = begin
    if length(prices[begin:idx]) < 13
        return missing
    end
    sma = sum(prices[(idx - 12):(idx - 6)]) / 6.0
    ema = sma
    for p in prices[(idx - 6):idx]
        ema = (p - ema) * (2.0 / 7.0) + ema
    end
    ema
end

@doc """ Generate synthetic funding rates

$(TYPEDSIGNATURES)

This function generates synthetic funding rates for a dataframe.
The synthetic funding rates are generated based on a factor `k` and a window `n`.
The window `n` is set to be the maximum of 2 and the ratio of 5 minutes to the period of the time frame of the dataframe.

"""
function synthfunding(df; k=3.0, n=max(2, Minute(5) ÷ period(timeframe!(df))))
    price_changes = diff(df.close)
    alpha = 2.0 / (n + 1.0)
    ema_price_changes = ema(price_changes; n, alpha)
    funding = [NaN, ema_price_changes ./ @view(df.close[2:end])...]
    for i in eachindex(funding)
        isnan(funding[i]) ? (funding[i] = 0.0) : break
    end
    df = DataFrame([:timestamp => copy(df.timestamp)])
    df[!, :funding] = funding
    df.timestamp[:] = apply.(TimeFrame(FUNDING_PERIOD), df.timestamp)
    gd = groupby(df, :timestamp)
    df = combine(gd, :funding => ((x) -> let m = mean(x)
        if m > 0.0
            maximum(x)
        elseif m < 0.0
            minimum(x)
        else
            last(x)
        end
    end); renamecols=false)
    df.funding[:] = df.funding .* k
    clamp!(df.funding, -0.05, 0.05)
    df
end

@doc """ Stub an asset instance with synthetic funding rates

$(TYPEDSIGNATURES)

This function stubs an asset instance with synthetic funding rates.
The synthetic funding rates are generated using the `synthfunding` function.
If the `force` parameter is set to `true`, the synthetic funding rates will replace any existing funding rates in the asset instance.

"""
function stub!(ai::AssetInstance, ::Val{:funding}; force=false)
    data = ohlcv(ai)
    if force || "funding" ∉ metadatakeys(data)
        funding = synthfunding(data)
        metadata!(data, "funding", funding, style=:default)
    end
end
