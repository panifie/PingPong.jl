module Example
using TimeTicks
using Engine
using Engine.Strategies
using Engine.Orders
using Instruments
using ExchangeTypes
using Misc: config
using Data.DataFramesMeta
using Data.DFUtils
using Lang
# using Lang: @lget!

# NOTE: do not export anything
@interface

const name = :Example
const exc = ExchangeID(:kucoinfutures)
const S = Strategy{name,exc}
const CACHE = Dict{Symbol,Any}()

@doc "Module initialization."
function __init__() end

exchange(::Type{S}) = exc
exchange(::S) = exchange(S)
function load(::Type{S}, cfg)
    pairs = marketsid(S)
    Strategy(Example, pairs, cfg)
end

function buy!(s::S, orders, ai, ats, ts)
    amount = s.config.base_amount
    if s.cash > amount
        sub!(s.cash, amount)
        push!(
            orders, Order(ai; amount=amount, price=ai.data[tf"15m"][ats, :open], date=ts)
        )
    end
end

function sell!(s::S, orders, ai, ats, ts)
    amount = s.config.base_amount
end

macro ignorefailed()
    orders = esc(:orders)
    quote
        !isempty($orders) && (empty!($orders); return nothing)
    end
end

function process(s::S, ts, orders, trades)
    @ignorefailed
    ats = available(tf"15m", ts)
    makeorders(ai) = begin
        if isbuy(s, ai, ats)
            buy!(s, orders, ai, ats, ts)
        elseif issell(s, ai, ats)
            push!(orders, Order(ai; amount=1, price=1, date=ts))
        end
    end
    foreach(makeorders, s.universe.data.instance)
end

function marketsid(::Type{S})
    ["ETH/USDT:USDT", "BTC/USDT:USDT", "XMR/USDT:USDT"]
end
marketsid(::S) = marketsid(S)

function assets(_::S)
    @lget! CACHE :assets Dict{AbstractAsset,ExchangeID}(
        parse(AbstractAsset, a) => exc for a in marketsid(S)
    )
end

warmup(::S) = Day(1)

closepair(ai, ts, tf=tf"15m") = begin
    data = ai.data[tf]
    prev = data[ts - tf, :close]
    ats = data[ts, :close]
    (prev, ats)
end

function isbuy(Strategy::S, ai, ts)
    prev, ats = closepair(ai, ts, tf"15m")
    ats / prev > 1.05
end

function issell(Strategy::S, ai, ts)
    prev, ats = closepair(ai, ts, tf"15m")
    prev / ats > 1.05
end

end
