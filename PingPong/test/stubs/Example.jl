module Example
# const pp = @eval Main PingPong

using Engine.Misc
using Engine.TimeTicks
using Engine.Instances.Instruments
using Engine.Exchanges.ExchangeTypes
using Data
using Data.DFUtils
using Data.DataFrames

using Engine.Strategies
using Engine: Strategies as st
using Engine.Instances: Instances as inst
using Engine.Executors
using Engine.OrderTypes

using Lang

__revise_mode__ = :eval
const CACHE = Dict{Symbol,Any}()

# # NOTE: do not export anything
@interface

const NAME = :Example
const EXCID = ExchangeID(:bybit)
const S{M} = Strategy{M,NAME,typeof(EXCID)}
const TF = tf"1m"

# function __init__() end

function ping!(::Type{S}, config, ::LoadStrategy)
    assets = marketsid(S)
    s = Strategy(Example, assets; load_data=false, config)
    s.attrs[:buydiff] = 1.01
    s.attrs[:selldiff] = 1.005
    s
end

ping!(_::S, ::WarmupPeriod) = begin
    Day(1)
end

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

function marketsid(::Type{S})
    ["ETH/USDT:USDT", "BTC/USDT:USDT", "XMR/USDT:USDT"]
end
marketsid(::S) = marketsid(S)

function buy!(s::S, ai, ats, ts)
    st.pop!(s, ai, Sell)
    @deassert ai.asset.qc == nameof(s.cash)
    price = closeat(ai.ohlcv, ats)
    amount = st.freecash(s) / 10.0 / price
    if amount > 0.0
        t = pong!(s, IOCOrder{Buy}, ai; amount, date=ts)
    end
end

function sell!(s::S, ai, ats, ts)
    st.pop!(s, ai, Buy)
    amount = max(inv(closeat(ai, ats)), inst.freecash(ai))
    price = closeat(ai.ohlcv, ats)
    if amount > 0.0
        t = pong!(s, IOCOrder{Sell}, ai; amount, date=ts)
    end
end

function isbuy(s::S, ai, ats)
    if s.cash > s.config.min_size
        closepair(ai, ats)
        isnothing(this_close[]) && return false
        this_close[] / prev_close[] > s.attrs[:buydiff]
    else
        false
    end
end

function issell(s::S, ai, ats)
    if ai.cash > 0.0
        closepair(ai, ats)
        isnothing(this_close[]) && return false
        prev_close[] / this_close[] > s.attrs[:selldiff]
    else
        false
    end
end

const this_close = Ref{Option{Float64}}(nothing)
const prev_close = Ref{Option{Float64}}(nothing)

function closepair(ai, ats, tf=tf"1m")
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

end
