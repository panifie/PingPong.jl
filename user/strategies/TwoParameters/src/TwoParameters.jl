module TwoParameters
using PingPong
const DESCRIPTION = "TwoParameters"
const EXC = :okx
const MARGIN = NoMargin
const TF = tf"1h"
@strategyenv!
using Indicators: rsi, ema, Indicators

SignalD = Dict{inst.AssetInstance,Union{Type{Buy},Type{Sell},Nothing}}

function indicators!(s, args...; timeframe=TF)
    for (n, func) in s[:params]
        pong!(
            (args...) -> func(args...; n),
            s,
            args...;
            cols=(Symbol(nameof(func), n),),
            timeframe,
        )
    end
end
function ping!(s::SC, ::ResetStrategy)
    s[:signals] = SignalD()
    s[:params] = ((20, ind_ema), (40, ind_ema), (14, ind_rsi))
    indicators!(s, InitData())
end
function ping!(_::SC, ::WarmupPeriod)
    Hour(80)
end
function ping!(s::SC, ts::DateTime, _)
    ats = available(s.timeframe, ts)
    signals = s[:signals]
    foreach(s.universe) do ai
        indicators!(s, ai, UpdateData())
        signals[ai] = signal(s, ai, ats)
    end
    action = resolve(signals)
    if isnothing(action)
        return nothing
    end
    eth = s[m"eth"]
    @linfo "Resolved signal" action sym = raw(eth)
    price = closeat(ohlcv(eth, s.timeframe), ats)
    closed = isdust(eth, price)
    if action == Buy && closed
        amount = freecash(s) / price - maxfees(eth)
        pong!(s, eth, MarketOrder{Buy}; date=ts, amount)
    elseif action == Sell && !closed
        pong!(s, eth, CancelOrders())
        pong!(s, eth, MarketOrder{Sell}; date=ts, amount=float(eth))
    end
end
function ping!(::Type{<:SC}, ::StrategyMarkets)
    String["BTC/USDT", "ETH/USDT"]
end

function signal(s, ai, ats)
    data = ohlcv(ai, TF)
    idx = dateindex(data, ats)
    ind_ema_short = data.ind_ema20[idx]
    ind_ema_long = data.ind_ema40[idx]
    ind_rsi = data.ind_rsi14[idx]
    if ind_ema_short > ind_ema_long && ind_rsi < 40
        Buy
    elseif ind_ema_short < ind_ema_long && ind_rsi > 60
        Sell
    end
end

function resolve(signals)
    vals = values(signals)
    if all(v == Buy for v in vals)
        Buy
    elseif all(v == Sell for v in vals)
        Sell
    end
end

function ind_ema(ohlcv, from_date; n)
    ohlcv = viewfrom(ohlcv, from_date; offset=-n)
    vec = ema(ohlcv.close; n)
    [vec;;]
end
function ind_rsi(ohlcv, from_date; kwargs...)
    ohlcv = viewfrom(ohlcv, from_date; offset=-14)
    vec = rsi(ohlcv.close; n=14)
    [vec;;]
end
end
