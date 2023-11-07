module Example
using PingPong

const DESCRIPTION = "Example"
const EXC = :phemex
const TF = tf"1m"

@strategyenv!
@optenv!

include("common.jl")

ping!(s::SC, ::ResetStrategy) = begin
    skip_watcher = attr(s, :skip_watcher, false)
    _reset!(s)
    _initparams!(s)
    _overrides!(s)
    skip_watcher || _tickers_watcher(s)
end
function ping!(t::Type{<:SC}, config, ::LoadStrategy)
    s = st.default_load(@__MODULE__, t, config)
    if s isa Union{PaperStrategy,LiveStrategy} && !(attr(s, :skip_watcher, false))
        _tickers_watcher(s)
    end
    s
end

ping!(_::SC, ::WarmupPeriod) = Day(1)

_initparams!(s) = begin
    params_index = st.attr(s, :params_index)
    empty!(params_index)
    params_index[:buydiff] = 1
    params_index[:selldiff] = 2
    params_index[:leverage] = 3
end

function ping!(s::T, ts::DateTime, _) where {T<:SC}
    ats = available(_timeframe(s), ts)
    makeorders(ai) = begin
        if issell(s, ai, ats)
            sell!(s, ai, ats, ts)
        elseif isbuy(s, ai, ats)
            buy!(s, ai, ats, ts)
        end
    end
    foreach(makeorders, s.universe.data.instance)
end

function ping!(::Type{<:SC}, ::StrategyMarkets)
    ["ETH/USDT", "BTC/USDT", "SOL/USDT"]
end

function ping!(::SC{ExchangeID{:bybit}}, ::StrategyMarkets)
    ["ETH/USDT", "BTC/USDT", "ATOM/USDT"]
end

function buy!(s, ai, ats, ts)
    pong!(s, ai, CancelOrders(); t=Sell)
    @deassert ai.asset.qc == nameof(s.cash)
    price = closeat(ai.ohlcv, ats)
    amount = st.freecash(s) / 10.0 / price
    if amount > 0.0
        ot, otsym = select_ordertype(s, Buy)
        kwargs = select_orderkwargs(otsym, Buy, ai, ats)
        t = pong!(s, ai, ot; amount, date=ts, kwargs...)
    end
end

function sell!(s, ai, ats, ts)
    pong!(s, ai, CancelOrders(); t=Buy)
    amount = max(inv(closeat(ai, ats)), inst.freecash(ai))
    if amount > 0.0
        ot, otsym = select_ordertype(s, Sell)
        kwargs = select_orderkwargs(otsym, Sell, ai, ats)
        t = pong!(s, ai, ot; amount, date=ts, kwargs...)
    end
end

function isbuy(s, ai, ats)
    if s.cash > s.config.min_size
        closepair(s, ai, ats)
        isnothing(_thisclose(s)) && return false
        _thisclose(s) / _prevclose(s) > s.attrs[:buydiff]
    else
        false
    end
end

function issell(s, ai, ats)
    if ai.cash > 0.0
        closepair(s, ai, ats)
        isnothing(_thisclose(s)) && return false
        _prevclose(s) / _thisclose(s) > s.attrs[:selldiff]
    else
        false
    end
end

## Optimization
function ping!(s::SC, ::OptSetup)
    # s.attrs[:opt_weighted_fitness] = weightsfunc
    (;
        ctx=Context(Sim(), tf"1h", dt"2020-", dt"2023-"),
        params=(; buydiff=1.005:0.001:1.02, selldiff=1.005:0.001:1.02),
        space=(kind=:MixedPrecisionRectSearchSpace, precision=[3, 3]),
    )
end
function ping!(s::SC, params, ::OptRun)
    s.attrs[:overrides] = (;
        timeframe=tf"1h",
        ordertype=:market,
        def_lev=1.0,
        buydiff=round(getparam(s, params, :buydiff); digits=3),
        selldiff=round(getparam(s, params, :selldiff); digits=3),
    )
    _overrides!(s)
end

function ping!(s::SC, ::OptScore)
    [values(stats.multi(s, :sortino; normalize=true))...]
    # [values(stats.multi(s, :sortino, :sharpe; normalize=true))...]
end
weightsfunc(weights) = weights[1] * 0.8 + weights[2] * 0.2

function ping!(::Type{<:SC}, ::StrategyMarkets)
    ["BTC/USDT", "ETH/USDT", "SOL/USDT"]
end

end
