module ExampleMargin

using PingPong
@strategyenv!
@contractsenv!
@optenv!
using Data: stub!

const NAME = :ExampleMargin
const EXCID = ExchangeID(:phemex)
const S{M} = Strategy{M,NAME,typeof(EXCID),Isolated}
const TF = tf"1m"
__revise_mode__ = :eval

include("common.jl")

# function __init__() end
function _reset_pos!(s, def_lev=get!(s.attrs, :def_lev, 2.5))
    for ai in s.universe
        pong!(s, ai, def_lev, UpdateLeverage(); pos=Long())
        pong!(s, ai, def_lev, UpdateLeverage(); pos=Short())
    end
end

ping!(s::S, ::ResetStrategy) = begin
    _reset!(s)
    # s.attrs[:buydiff] = 1.01
    # s.attrs[:selldiff] = 1.012
    s.attrs[:long_k] = 0.02
    s.attrs[:short_k] = 0.02
    s.attrs[:per_order_leverage] = false
    _overrides!(s)
    _reset_pos!(s)
    # Generate stub funding rate data, only in sim mode
    if s isa Strategy{Sim}
        for ai in s.universe
            stub!(ai, Val(:funding))
        end
    end
end
_initparams!() = begin
    empty!(params_index)
    params_index[:buydiff] = 1
    params_index[:selldiff] = 2
    params_index[:leverage] = 3
end
function ping!(::Type{<:S}, config, ::LoadStrategy)
    assets = marketsid(S)
    config.margin = Isolated()
    s = Strategy(@__MODULE__, assets; config)
    @assert s isa IsolatedStrategy
    _reset!(s)
    _reset_pos!(s)
    _initparams!()
    s
end

ping!(_::S, ::WarmupPeriod) = Day(1)

function ping!(s::T, ts, _) where {T<:S}
    ats = available(tf"15m", ts)
    makeorders(ai) = begin
        pos = nothing
        lev = nothing
        if isbuy(s, ai, ats, pos)
            buy!(s, ai, ats, ts; lev)
        elseif issell(s, ai, ats, pos)
            sell!(s, ai, ats, ts; lev)
        end
    end
    foreach(makeorders, s.universe.data.instance)
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

const nc = Ref(0)

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

## Optimization
function ping!(s::S, ::OptSetup)
    # s.attrs[:opt_weighted_fitness] = weightsfunc
    (;
        ctx=Context(Sim(), tf"1h", dt"2020-", dt"2023-"),
        params=(;
            # buydiff=1.005:0.005:1.02, selldiff=1.005:0.005:1.02, leverage=1.0:0.5:20.0
            buydiff=1.005:0.001:1.02, selldiff=1.005:0.001:1.02, leverage=1.0:1.0:100.0
        ),
        space=(kind=:MixedPrecisionRectSearchSpace, precision=[3, 3, 1]),
    )
end
function ping!(s::S, params, ::OptRun)
    s.attrs[:overrides] = (;
        timeframe=tf"1h",
        ordertype=:market,
        def_lev=getparam(params, :leverage),
        buydiff=getparam(params, :buydiff),
        selldiff=getparam(params, :selldiff),
    )
    _overrides!(s)
    _reset_pos!(s)
end

function ping!(s::S, ::OptScore)::Vector
    # [values(stats.multi(s, :total, :sortino, normalize=true))...]
    [values(stats.multi(s, :total, :sortino; normalize=true))...]
end

end
