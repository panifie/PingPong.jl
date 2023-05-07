module ExampleMargin

using PingPong
@strategyenv!

const NAME = :ExampleMargin
const EXCID = ExchangeID(:phemex)
const S{M} = Strategy{M,NAME,typeof(EXCID),Isolated}
const TF = tf"1m"
__revise_mode__ = :eval

include("common.jl")

# function __init__() end

ping!(s::S, ::ResetStrategy) = _reset!(s)
function ping!(::Type{<:S}, ::LoadStrategy, config)
    assets = marketsid(S)
    config.margin = Isolated()
    s = Strategy(@__MODULE__, assets; config)
    _reset!(s)
    s
end

ping!(_::S, ::WarmupPeriod) = Day(1)

levat(ai, ats) = clamp(2.0 * highat(ai, ats) / lowat(ai, ats), 1.0, 100.0)

function ping!(s::T where {T<:S}, ts, _)
    pong!(s, UpdateOrders(), ts)
    ats = available(tf"15m", ts)
    makeorders(ai) = begin
        pos = longorshort(s, ai, ats)
        if issell(s, ai, ats, pos)
            lev = levat(ai, ats)
            sell!(s, ai, ats, ts)
        elseif isbuy(s, ai, ats)
            lev = levat(ai, ats)
            buy!(s, ai, ats, ts)
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
    if cash(ai, Long()) > 0.0
        closepair(ai, ats)
        isnothing(this_close[]) && return false
        prev_close[] / this_close[] > s.attrs[:selldiff]
    else
        false
    end
end

function buy!(s::S, ai, ats, ts)
    pong!(s, CancelOrders(), ai, Sell)
    @deassert ai.asset.qc == nameof(s.cash)
    price = closeat(ai.ohlcv, ats)
    amount = st.freecash(s) / 10.0 / price
    if amount > 0.0
        ot, otsym = select_ordertype(s, Buy)
        kwargs = select_orderkwargs(otsym, Buy, ai, ats)
        t = pong!(s, ot, ai; amount, date=ts, kwargs...)
    end
end

function sell!(s::S, ai, ats, ts)
    pong!(s, CancelOrders(), ai, Buy)
    amount = max(inv(closeat(ai, ats)), inst.freecash(ai))
    if amount > 0.0
        ot, otsym = select_ordertype(s, Sell)
        kwargs = select_orderkwargs(otsym, Sell, ai, ats)
        t = pong!(s, ot, ai; amount, date=ts, kwargs...)
    end
end

end
