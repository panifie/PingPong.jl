using .Lang: @lget!, splitkws
using .ExchangeTypes
using .Exchanges: issandbox
using .Misc.TimeToLive
using .Misc: LittleDict
using .Python: pytofloat, Py, @pystr, PyDict, @pyfetch, pyfetch, pyconvert
using .Instances: bc, qc
import .st: current_total, MarginStrategy, NoMarginStrategy

@enum BalanceStatus TotalBalance FreeBalance UsedBalance
const BalanceTTL = Ref(Second(5))
const BalanceCacheDict5 = safettl(
    Tuple{ExchangeID,Bool}, Dict{Tuple{BalanceStatus,Symbol},Py}, BalanceTTL[]
)
const BalanceCacheSyms7 = safettl(
    Tuple{ExchangeID,Bool}, Dict{Tuple{Symbol,BalanceStatus,Symbol},Float64}, BalanceTTL[]
)

function Base.string(v::BalanceStatus)
    if v == TotalBalance
        "total"
    elseif v == FreeBalance
        "free"
    elseif v == UsedBalance
        "used"
    end
end

function _fetch_balance(exc, args...; kwargs...)
    pyfetch(first(exc, :fetchBalanceWs, :fetchBalance), args...; splitkws(:type; kwargs).rest...)
end
function _balancedict!(exc)
    @lget! BalanceCacheDict5 (exchangeid(exc), issandbox(exc)) Dict{
        Tuple{BalanceStatus,Symbol},Py
    }()
end
function _symdict!(exc)
    @lget! BalanceCacheSyms7 (exchangeid(exc), issandbox(exc)) Dict{
        Tuple{Symbol,BalanceStatus,Symbol},Float64
    }()
end
_balancetype(_, _) = Symbol()

@doc "Fetch balance, caching for $(BalanceTTL[])"
function balance(exc::Exchange, args...; type=Symbol(), status=TotalBalance, kwargs...)
    d = _balancedict!(exc)
    @lget! d (status, type) begin
        b = _fetch_balance(exc, args...; type, kwargs...)
        b[@pystr(lowercase(string(status)))]
    end
end

_pystrsym(v::String) = @pystr(uppercase(v))
_pystrsym(v::Symbol) = @pystr(uppercase(string(v)))

@doc "Fetch balance for symbol, caching for $(BalanceTTL[])."
function balance(
    exc::Exchange,
    sym::Union{<:AssetInstance,Symbol},
    args...;
    type=Symbol(),
    status=TotalBalance,
    kwargs...,
)
    d = _symdict!(exc)
    @lget! d (sym, status, type) begin
        b = balance(exc, args...; type, status, kwargs...)
        pyconvert(Float64, get_py(b, _pystrsym(sym), 0.0))
    end
end

@doc "Fetch balance forcefully, caching for $(BalanceTTL[])."
function balance!(
    exc::Exchange, args...; raw=false, type=Symbol(), status=TotalBalance, kwargs...
)
    b = _fetch_balance(exc, args...; type, kwargs...)[@pystr(lowercase(string(status)))]
    d = _balancedict!(exc)
    d[(status, type)] = b
    empty!(_symdict!(exc))
    raw ? b : pyconvert(Dict{Symbol,DFT}, b)
end

@doc "Fetch balance forcefully for symbol, caching for $(BalanceTTL[])."
function balance!(
    exc::Exchange,
    sym::Union{String,Symbol},
    args...;
    type=Symbol(),
    status=TotalBalance,
    kwargs...,
)
    b = balance!(exc, args...; type, status, kwargs...)
    d = _symdict!(exc)
    v = pyconvert(Float64, get_py(b, _pystrsym(sym), 0.0))
    d[(Symbol(sym), status, type)] = v
    pyconvert(DFT, v)
end

function balance(s::LiveStrategy, args...; kwargs...)
    balance(exchange(s), args...; kwargs...)
end

function balance(s::LiveStrategy, sym, args...; kwargs...)
    balance(exchange(s), sym, args...; kwargs...)
end

function balance!(s::LiveStrategy, args...; kwargs...)
    balance!(exchange(s), args...; kwargs...)
end

function current_total(
    s::LiveStrategy{N,E,M}, price_func=lastprice; type=:swap, code=_pystrsym(nameof(s.cash))
) where {N,E<:ExchangeID,M<:WithMargin}
    tot = [zero(DFT)]
    bal = balance(s; type, code)
    @sync for ai in s.universe
        amount = get(bal, _pystrsym(bc(ai)), zero(DFT)) |> pytofloat
        @async let v = price_func(ai) * amount
            tot[] += v
        end
    end
    tot[] += get(bal, string(nameof(s.cash)), s.cash.value) |> pytofloat
    tot[]
end

function current_total(
    s::LiveStrategy{N,E,NoMargin},
    price_func=lastprice;
    type=:spot,
    code=_pystrsym(nameof(s.cash)),
) where {N,E<:ExchangeID}
    bal = balance(s; type, code)
    tot = get(bal, string(nameof(s.cash)), s.cash.value) |> pytofloat
    @sync for ai in s.universe
        amount = get(bal, _pystrsym(bc(ai)), zero(DFT)) |> pytofloat
        @async let v = price_func(ai) * amount
            # NOTE: `x += y` is rewritten as x = x + y
            # Because `price_func` can be async, the value of `x` might be stale by
            # the time `y` is fetched, and the assignment might clobber the most
            # recent value of `x`
            tot += v
        end
    end
    tot
end

include("adhoc/balance.jl")

export BalanceStatus, TotalBalance, FreeBalance, UsedBalance
export balance, balance!
