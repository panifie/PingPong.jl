module SimpleStrategy
using PingPong
const DESCRIPTION = "SimpleStrategy"
const EXC = :binance
const MARGIN = NoMargin
const TF = tf"1d"
@strategyenv!
using .Engine.Simulations: mean
function ping!(t::Type{<:SC}, config, ::LoadStrategy)
    config.min_timeframe = tf"1d"
    config.timeframes = [tf"1d"]
    st.default_load(@__MODULE__, t, config)
end
function ping!(s::SC, ::ResetStrategy)
    pong!(s, WatchOHLCV())
end
function ping!(_::SC, ::WarmupPeriod)
    Day(15)
end
function ping!(s::SC, ts::DateTime, _)
    ats = available(s.timeframe, ts)
    foreach(s.universe) do ai
        df = ohlcv(ai)
        idx = dateindex(df, ats)
        if idx > 15
            ma7d = mean(@view df.close[(idx - 7):idx])
            ma15d = mean(@view df.close[(idx - 15):idx])
            side = ifelse(ma7d > ma15d, Buy, Sell)
            pong!(s, ai, MarketOrder{side}; date=ts, amount=0.001)
        end
    end
end
const ASSETS = ["BTC/USDT"]
function ping!(::Union{<:SC,Type{<:SC}}, ::StrategyMarkets)
    ASSETS
end
end
