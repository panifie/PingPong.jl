module ExampleMargin

using PingPong
@strategyenv!
using Data: stub!

const NAME = :ExampleMargin
const EXCID = ExchangeID(:phemex)
const S{M} = Strategy{M,NAME,typeof(EXCID),Isolated}
const TF = tf"1m"
__revise_mode__ = :eval

include("common.jl")

# function __init__() end
_reset_pos!(s) = begin
    s.attrs[:longdiff] = 1.0075
    s.attrs[:selldiff] = 1.0025
end

ping!(s::S, ::ResetStrategy) = begin
    _reset!(s)
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
    _reset!(s)
    _reset_pos!(s)
    s
end

ping!(_::S, ::WarmupPeriod) = Day(1)

levat(ai, ats) = clamp(2.0 * highat(ai, ats) / lowat(ai, ats), 1.0, 100.0)

function ping!(s::T, ts, _) where {T<:S}
    pong!(s, ts, UpdateOrders())
    ats = available(tf"15m", ts)
    makeorders(ai) = begin
        pos = longorshort(s, ai, ats)
        let sop = opposite(pos)
            if isopen(ai, sop)
                pong!(s, ai, sop, ts, PositionClose())
            end
        end
        lev = levat(ai, ats) * 2.0
        pong!(ai, lev, UpdateLeverage(); pos)
        if inst.isshort(pos) && issell(s, ai, ats, pos)
            sell!(s, ai, ats, ts; lev)
        elseif inst.islong(pos) && isbuy(s, ai, ats, pos)
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
    if s.cash > s.config.min_size
        closepair(ai, ats)
        isnothing(this_close[]) && return false
        this_close[] / prev_close[] > s.attrs[:buydiff]
    else
        false
    end
end

function issell(s::S, ai, ats, pos)
    if !iszero(cash(ai, pos))
        closepair(ai, ats)
        isnothing(this_close[]) && return false
        prev_close[] / this_close[] > s.attrs[:selldiff]
    else
        false
    end
end

function buy!(s::S, ai, ats, ts; lev)
    pong!(s, ai, CancelOrders(); t=Sell)
    @deassert ai.asset.qc == nameof(s.cash)
    price = closeat(ai.ohlcv, ats)
    amount = st.freecash(s) / 10.0 / price
    # stype = Strategy{<:st.ExecMode,N,<:st.ExchangeID,st.Isolated,C} where {N,C}
    # @show typeof(s) stype{:ExampleMargin}
    # @assert s isa stype{:ExampleMargin}
    if amount > 0.0
        ot, otsym = select_ordertype(s, Buy)
        kwargs = select_orderkwargs(otsym, Buy, ai, ats)
        t = pong!(s, ai, ot; amount, date=ts, kwargs...)
    end
end

function sell!(s::S, ai, ats, ts)
    pong!(s, ai, Buy, CancelOrders())
    amount = max(inv(closeat(ai, ats)), inst.freecash(ai))
    if amount > 0.0
        ot, otsym = select_ordertype(s, Sell)
        kwargs = select_orderkwargs(otsym, Sell, ai, ats)
        t = pong!(s, ai, ot; amount, date=ts, kwargs...)
    end
end

end
