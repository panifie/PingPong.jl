module Example

using PingPong
@strategyenv!
@optenv!

const NAME = :Example
const EXCID = ExchangeID(:phemex)
const S{M} = Strategy{<:ExecMode,NAME,typeof(EXCID),NoMargin,:USDT}
const TF = tf"1m"

__revise_mode__ = :eval
include("common.jl")

ping!(s::S, ::ResetStrategy) = begin
    _reset!(s)
    _initparams!(s)
    _overrides!(s)
    _tickers_watcher(s)
end
function ping!(::Type{<:S}, config, ::LoadStrategy)
    assets = marketsid(S)
    s = Strategy(@__MODULE__, assets; config, sandbox=(config.mode != Paper()))
    _reset!(s)
    _tickers_watcher(s)
    if s isa Union{PaperStrategy,LiveStrategy}
        stub!(s.universe, s[:tickers_watcher].view; fromfiat=false)
    end
    s
end

ping!(_::S, ::WarmupPeriod) = Day(1)

_initparams!(s) = begin
    params_index = st.attr(s, :params_index)
    empty!(params_index)
    params_index[:buydiff] = 1
    params_index[:selldiff] = 2
    params_index[:leverage] = 3
end

function ping!(s::T, ts::DateTime, _) where {T<:S}
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

function marketsid(::Type{<:S})
    ["ETH/USDT", "BTC/USDT", "SOL/USDT"]
end

function buy!(s::S, ai, ats, ts)
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

function sell!(s::S, ai, ats, ts)
    pong!(s, ai, CancelOrders(); t=Buy)
    amount = max(inv(closeat(ai, ats)), inst.freecash(ai))
    if amount > 0.0
        ot, otsym = select_ordertype(s, Sell)
        kwargs = select_orderkwargs(otsym, Sell, ai, ats)
        t = pong!(s, ai, ot; amount, date=ts, kwargs...)
    end
end

function isbuy(s::S, ai, ats)
    if s.cash > s.config.min_size
        closepair(s, ai, ats)
        isnothing(_thisclose(s)) && return false
        _thisclose(s) / _prevclose(s) > s.attrs[:buydiff]
    else
        false
    end
end

function issell(s::S, ai, ats)
    if ai.cash > 0.0
        closepair(s, ai, ats)
        isnothing(_thisclose(s)) && return false
        _prevclose(s) / _thisclose(s) > s.attrs[:selldiff]
    else
        false
    end
end

## Optimization
function ping!(s::S, ::OptSetup)
    # s.attrs[:opt_weighted_fitness] = weightsfunc
    (;
        ctx=Context(Sim(), tf"1h", dt"2020-", dt"2023-"),
        params=(; buydiff=1.005:0.001:1.02, selldiff=1.005:0.001:1.02),
        space=(kind=:MixedPrecisionRectSearchSpace, precision=[3, 3]),
    )
end
function ping!(s::S, params, ::OptRun)
    s.attrs[:overrides] = (;
        timeframe=tf"1h",
        ordertype=:market,
        def_lev=1.0,
        buydiff=round(getparam(s, params, :buydiff); digits=3),
        selldiff=round(getparam(s, params, :selldiff); digits=3),
    )
    _overrides!(s)
end

function ping!(s::S, ::OptScore)
    [values(stats.multi(s, :sortino; normalize=true))...]
    # [values(stats.multi(s, :sortino, :sharpe; normalize=true))...]
end
weightsfunc(weights) = weights[1] * 0.8 + weights[2] * 0.2

end
