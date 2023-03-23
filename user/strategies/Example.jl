module Example
using Lang
using Misc
using TimeTicks
using Instruments
using ExchangeTypes
using Data
using Data.DFUtils
using Data: DataFrame

using Engine
using Engine.Strategies
using Engine.Executors
using Engine.Orders: limitorder, LimitOrder, Buy, Sell

__revise_mode__ = :eval
const CACHE = Dict{Symbol,Any}()

# NOTE: do not export anything
@interface

const NAME = :Example
const EXCID = ExchangeID(:bybit)
const S{M} = Strategy{M,NAME,typeof(EXCID)}
const TF = tf"1m"

function __init__() end

function ping!(::Type{S}, ::LoadStrategy, config)
    assets = marketsid(S)
    Strategy(Example; assets, config)
end

function buy!(s::S, ai, ats, ts)
    @deassert ai.asset.qc == nameof(s.cash)
    amount = s.cash / closeat(ai.ohlcv, ats) / 10.0
    pong!(s, LimitOrder{Buy}, ai; amount, date=ts)
end

function sell!(s::S, ai, ats, ts)
    amount = ai.cash / 10.0
    pong!(s, LimitOrder{Sell}, ai; amount, date=ts)
end

function marketsid(::Type{S})
    ["ETH/USDT:USDT", "BTC/USDT:USDT", "XMR/USDT:USDT"]
end
marketsid(::S) = marketsid(S)

ping!(::S, ::WarmupPeriod) = Day(1)

function ping!(s::S, ts, _)
    pong!(s, ts, UpdateOrders())
    ats = available(tf"15m", ts)
    makeorders(ai) = begin
        if issell(s, ai, ats)
            sell!(s, ai, ats, ts)
        elseif isbuy(s, ai, ats)
            buy!(s, ai, ats, ts)
        end
    end
    foreach(makeorders, s.universe.data.instance)
end

const this_close = Ref{Option{Float64}}(nothing)
const prev_close = Ref{Option{Float64}}(nothing)

function closepair(ai, ats, tf=tf"15m")
    data = ai.data[tf]
    prev_date = ats - tf
    if data.timestamp[begin] > prev_date
        this_close[] = nothing
        return nothing
    end
    this_close[] = closeat(data, ats)
    prev_close[] = closeat(data, prev_date)
    nothing
end

function isbuy(s::S, ai, ats)
    if s.cash > s.config.min_size
        closepair(ai, ats)
        isnothing(this_close[]) && return false
        this_close[] / prev_close[] > 1.01
    else
        false
    end
end

function issell(_::S, ai, ats)
    if ai.cash > 0.0
        closepair(ai, ats)
        isnothing(this_close[]) && return false
        prev_close[] / this_close[] > 1.01
    else
        false
    end
end

end
