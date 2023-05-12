module Example

using PingPong
@strategyenv!

const NAME = :Example
const EXCID = ExchangeID(:phemex)
const S{M} = Strategy{<:ExecMode,NAME,typeof(EXCID),NoMargin,:USDT}
const TF = tf"1m"

__revise_mode__ = :eval
include("common.jl")

ping!(s::S, ::ResetStrategy) = _reset!(s)
function ping!(::Type{<:S}, config, ::LoadStrategy)
    assets = marketsid(S)
    s = Strategy(@__MODULE__, assets; config)
    _reset!(s)
    s
end

ping!(_::S, ::WarmupPeriod) = Day(1)

function ping!(s::T where {T<:S}, ts, _)
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

function marketsid(::Type{<:S})
    ["ETH/USDT", "BTC/USDT", "SOL/USDT"]
end

function buy!(s::S, ai, ats, ts)
    pong!(s, ai, CancelOrders(), t=Sell)
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
    pong!(s, ai, CancelOrders(), t=Buy)
    amount = max(inv(closeat(ai, ats)), inst.freecash(ai))
    if amount > 0.0
        ot, otsym = select_ordertype(s, Sell)
        kwargs = select_orderkwargs(otsym, Sell, ai, ats)
        t = pong!(s, ai, ot; amount, date=ts, kwargs...)
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

end
