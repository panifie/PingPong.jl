module TwoIntervals
using PingPong

const DESCRIPTION = "TwoIntervals"
const EXC = :binance
const TF = tf"15m"
const MARGIN = NoMargin

@strategyenv!
using Indicators: ema, rsi, Indicators
@enum Trend Down = 0 Up = 1

function ping!(s::SC, ::ResetStrategy)
    for n in (15, 40)
        pong!(
            (args...) -> ind_ema(args...; n),
            s,
            InitData();
            cols=(Symbol(:ema, n),),
            timeframe=tf"1h",
        )
        pong!(ind_rsi, s, InitData(); cols=(:rsi,), timeframe=tf"15m")
    end
end

function ping!(_::SC, ::WarmupPeriod)
    Day(1)
end
function update_data!(s, ai)
    for n in (15, 40)
        pong!(
            (args...) -> ind_ema(args...; n),
            s,
            ai,
            UpdateData();
            cols=(Symbol(:ema, n),),
            timeframe=tf"1h",
        )
    end
    pong!(ind_rsi, s, ai, UpdateData(); cols=(:rsi,), timeframe=tf"1h")
end
function handler(s, ai, ats, date)
    ohlcv = ai.data[tf"1h"]
    idx = dateindex(ohlcv, ats)
    idx < 1 && return nothing
    this_trend = ifelse(ohlcv[idx, :ema15] > ohlcv[idx, :ema40], Down, Up)
    this_rsi = ai.data[tf"15m"][ats, :rsi]
    if this_trend == Up && this_rsi < 40
        price = closeat(ohlcv, ats)
        amount = freecash(s) / price
        @linfo "Buying" asset = raw(ai) amount price
        pong!(s, ai, MarketOrder{Buy}; date, amount)
    elseif this_trend == Down && this_rsi > 60
        price = closeat(ohlcv, ats)
        if !isdust(ai, price)
            amount = float(ai)
            @linfo "Selling" asset = raw(ai) amount price
            pong!(s, ai, CancelOrders())
            pong!(s, ai, MarketOrder{Sell}; date, amount)
        end
    end
end
function ping!(s::SC, ts::DateTime, _)
    ats = available(tf"1h", ts)
    foreach(s.universe) do ai
        update_data!(s, ai)
        handler(s, ai, ats, ts)
    end
end
function ping!(::Type{<:SC}, ::StrategyMarkets)
    String["BTC/USDT"]
end

function ind_ema(ohlcv, from_date; n)
    ohlcv = viewfrom(ohlcv, from_date; offset=-n)
    vec = ema(ohlcv.close; n)
    [vec;;]
end
function ind_rsi(ohlcv, from_date)
    @assert timeframe!(ohlcv) == tf"15m"
    ohlcv = viewfrom(ohlcv, from_date; offset=-14)
    vec = rsi(ohlcv.close; n=14)
    [vec;;]
end
end
