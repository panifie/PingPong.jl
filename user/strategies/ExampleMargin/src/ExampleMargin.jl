module ExampleMargin

using PingPong
@strategyenv!
@contractsenv!
using Data: stub!
using Watchers.WatchersImpls: ccxt_ohlcv_tickers_watcher, start!, load!

const NAME = :ExampleMargin
const EXCID = ExchangeID(:phemex)
const S{M} = Strategy{M,NAME,typeof(EXCID),Isolated}
const TF = tf"1m"
__revise_mode__ = :eval

include("common.jl")

# function __init__() end
function _reset_pos!(s, def_lev=get!(s.attrs, :def_lev, 1.5))
    s.attrs[:longdiff] = 1.02
    s.attrs[:buydiff] = 1.01
    s.attrs[:selldiff] = 1.012
    s.attrs[:long_k] = 0.02
    s.attrs[:short_k] = 0.02
    s.attrs[:per_order_leverage] = true
    s.attrs[:verbose] = false
    for ai in s.universe
        pong!(s, ai, def_lev, UpdateLeverage(); pos=Long())
        pong!(s, ai, def_lev, UpdateLeverage(); pos=Short())
    end
end

ping!(s::S, ::ResetStrategy) = begin
    _reset!(s)
    _reset_pos!(s)
    # Generate stub funding rate data, only in sim mode
    if S <: Strategy{Sim}
        for ai in s.universe
            stub!(ai, Val(:funding))
        end
    else
    end
end
function ping!(::Type{<:S}, config, ::LoadStrategy)
    assets = marketsid(S)
    config.margin = Isolated()
    s = Strategy(@__MODULE__, assets; config, sandbox=(config.mode != Paper()))
    @assert s isa IsolatedStrategy
    _reset!(s)
    _reset_pos!(s)
    if s isa Union{PaperStrategy,LiveStrategy}
        exc = getexchange!(s.exchange)
        w = ccxt_ohlcv_tickers_watcher(exc; syms=marketsid(s))
        start!(w)
        @sync for sym in marketsid(s)
            @async load!(w, sym)
        end
        setattr!(s, :tickers_watcher, w)
    end
    s
end

ping!(_::S, ::WarmupPeriod) = Day(1)

function ping!(s::T, ts::DateTime, _) where {T<:S}
    ats = available(tf"15m", ts)
    foreach(s.universe) do ai
        pos = nothing
        lev = nothing
        if isbuy(s, ai, ats, pos)
            buy!(s, ai, ats, ts; lev)
        elseif issell(s, ai, ats, pos)
            sell!(s, ai, ats, ts; lev)
        end
    end
end

function marketsid(::Type{<:S})
    ["ETH/USDT:USDT", "BTC/USDT:USDT", "SOL/USDT:USDT"]
end

function longorshort(s::S, ai, ats)
    closepair(s, ai, ats)
    if _thisclose(s) / _prevclose(s) > s.attrs[:buydiff]
        Long()
    else
        Short()
    end
end

function isbuy(s::S, ai, ats, pos)
    closepair(s, ai, ats)
    isnothing(_thisclose(s)) && return false
    _thisclose(s) / _prevclose(s) > s.attrs[:buydiff]
end

function issell(s::S, ai, ats, pos)
    closepair(s, ai, ats)
    isnothing(_thisclose(s)) && return false
    _prevclose(s) / _thisclose(s) > s.attrs[:selldiff]
end

_levk(s, ::Long) = s.attrs[:long_k]
_levk(s, ::Short) = s.attrs[:short_k]
function update_leverage!(s, ai, pos, ats)
    s.attrs[:per_order_leverage] || return nothing
    lev = let r = highat(ai, ats) / lowat(ai, ats)
        diff = abs(1.0 - r)
        clamp(_levk(s, pos) / diff, 1.0, 100.0)
    end
    pong!(s, ai, lev, UpdateLeverage(); pos)
end

function buy!(s::S, ai, ats, ts; lev)
    pong!(s, ai, CancelOrders(); t=Sell)
    @deassert ai.asset.qc == nameof(s.cash)
    p = @something inst.position(ai) inst.position(ai, Long())
    ok = false
    if inst.islong(p)
        c = st.freecash(s)
        if c > ai.limits.cost.min
            order_p = Long()
            c = max(ai.limits.cost.min, c / 10.0)
            price = closeat(ai.ohlcv, ats)
            amount = c / price
            ok = true
        end
    else
        amount = abs(inst.freecash(ai, Short()))
        if amount > 0.0
            order_p = Short()
            ok = true
        end
    end
    if ok
        update_leverage!(s, ai, order_p, ats)
        ot, otsym = select_ordertype(s, Buy, order_p)
        kwargs = select_orderkwargs(otsym, Buy, ai, ats)
        t = pong!(s, ai, ot; amount, date=ts, kwargs...)
        if !isnothing(t) && order_p == Short()
            ot, otsym = select_ordertype(s, Buy, Long())
            kwargs = select_orderkwargs(otsym, Buy, ai, ats)
            t = pong!(s, ai, ot; amount, date=ts, kwargs...)
        end
    end
end

function sell!(s::S, ai, ats, ts; lev)
    pong!(s, ai, CancelOrders(); t=Buy)
    p = @something inst.position(ai) inst.position(ai, Short())
    price = closeat(ai.ohlcv, ats)
    ok = false
    if inst.isshort(p)
        amount = st.freecash(s) / 10.0 / price
        if amount > ai.limits.amount.min
            order_p = Short()
            ok = true
        end
    else
        amount = inst.freecash(ai, Long())
        if amount > 0.0
            order_p = Long()
            ok = true
        end
    end
    if ok
        update_leverage!(s, ai, order_p, ats)
        ot, otsym = select_ordertype(s, Sell, order_p)
        kwargs = select_orderkwargs(otsym, Sell, ai, ats)
        t = pong!(s, ai, ot; amount, date=ts, kwargs...)
        if !isnothing(t) && order_p == Long()
            ot, otsym = select_ordertype(s, Sell, Short())
            kwargs = select_orderkwargs(otsym, Sell, ai, ats)
            t = pong!(s, ai, ot; amount, date=ts, kwargs...)
        end
    end
end

end
