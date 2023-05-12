module ExampleMargin

using PingPong
@strategyenv!
@contractsenv!
using Data: stub!

const NAME = :ExampleMargin
const EXCID = ExchangeID(:phemex)
const S{M} = Strategy{M,NAME,typeof(EXCID),Isolated}
const TF = tf"1m"
__revise_mode__ = :eval

include("common.jl")

# function __init__() end
_reset_pos!(s) = begin
    s.attrs[:longdiff] = 1.01
    s.attrs[:selldiff] = 1.0075
    s.attrs[:long_mul] = 2.0
    s.attrs[:short_mul] = 20.0
end

ping!(s::S, ::ResetStrategy) = begin
    _reset!(s)
    _reset_pos!(s)
    # Generate stub funding rate data, only in sim mode
    if S <: Strategy{Sim}
        for ai in s.universe
            stub!(ai, Val(:funding))
        end
    end
end
function ping!(::Type{<:S}, config, ::LoadStrategy)
    assets = marketsid(S)
    config.margin = Isolated()
    s = Strategy(@__MODULE__, assets; config)
    @assert s isa IsolatedStrategy
    _reset!(s)
    _reset_pos!(s)
    s
end

ping!(_::S, ::WarmupPeriod) = Day(1)

levat(ai, ats) = clamp(2.0 * highat(ai, ats) / lowat(ai, ats), 1.0, 100.0)

function ping!(s::T, ts, _) where {T<:S}
    ats = available(tf"15m", ts)
    makeorders(ai) = begin
        pos = nothing
        lev = nothing
        if issell(s, ai, ats, pos)
            sell!(s, ai, ats, ts; lev)
        elseif isbuy(s, ai, ats, pos)
            buy!(s, ai, ats, ts; lev)
        end
    end
    foreach(makeorders, s.universe.data.instance)
end

function marketsid(::Type{<:S})
    ["ETH/USDT:USDT", "BTC/USDT:USDT", "SOL/USDT:USDT"]
end

function longorshort(s::S, ai, ats)
    closepair(ai, ats)
    if this_close[] / prev_close[] > s.attrs[:buydiff]
        Long()
    else
        Short()
    end
end

function isbuy(s::S, ai, ats, pos)
    closepair(ai, ats)
    isnothing(this_close[]) && return false
    this_close[] / prev_close[] > s.attrs[:buydiff]
end

function issell(s::S, ai, ats, pos)
    closepair(ai, ats)
    isnothing(this_close[]) && return false
    prev_close[] / this_close[] > s.attrs[:selldiff]
end

_levmul(s, ::Long) = s.attrs[:long_mul]
_levmul(s, ::Short) = s.attrs[:short_mul]
function update_leverage!(s, ai, pos, ats)
    lev = levat(ai, ats) * _levmul(s, pos)
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
    p = inst.position(ai)
    # Buy during sell
    isnothing(p) && return nothing
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
