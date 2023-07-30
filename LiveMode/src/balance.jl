using .Lang: @lget!, splitkws
using .ExchangeTypes
using .Misc.TimeToLive
using .Misc: LittleDict
using .Python
import .st: current_total

@enum BalanceStatus TotalBalance FreeBalance UsedBalance
const BalanceTTL = Ref(Second(5))
const BalanceCacheDict4 = safettl(
    ExchangeID, Dict{Tuple{BalanceStatus,Symbol},Py}, BalanceTTL[]
)
const BalanceCacheSyms6 = safettl(
    ExchangeID, Dict{Tuple{Symbol,BalanceStatus,Symbol},Float64}, BalanceTTL[]
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
    pyfetch(exc.py.fetchBalance, args...; splitkws(:type; kwargs).rest...)
end
function _balancedict!(exc)
    @lget! BalanceCacheDict4 exc.id Dict{Tuple{BalanceStatus,Symbol},Py}()
end
function _symdict!(exc)
    @lget! BalanceCacheSyms6 exc.id Dict{Tuple{Symbol,BalanceStatus,Symbol},Float64}()
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
        pyconvert(Float64, b.get(_pystrsym(sym), 0.0))
    end
end

@doc "Fetch balance forcefully, caching for $(BalanceTTL[])."
function balance!(exc::Exchange, args...; raw=false, type=Symbol(), status=TotalBalance, kwargs...)
    b = _fetch_balance(exc, args...; type, kwargs...)[@pystr(lowercase(string(status)))]
    d = _balancedict!(exc)
    d[(status, type)] = b
    empty!(_symdict!(exc))
    raw ? b : pyconvert(Dict{Symbol, DFT}, b)
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
    v = pyconvert(Float64, b.get(_pystrsym(sym), 0.0))
    d[(Symbol(sym), status, type)] = v
    pyconvert(DFT, v)
end

function balance(s::LiveStrategy, args...; kwargs...)
    balance(getexchange!(exchange(s)), args...; kwargs...)
end

function balance(s::LiveStrategy, sym, args...; kwargs...)
    balance(getexchange!(exchange(s)), sym, args...; kwargs...)
end

function balance!(s::LiveStrategy, args...; kwargs...)
    balance!(getexchange!(exchange(s)), args...; kwargs...)
end

function current_total(s::LiveStrategy)
    tot = zero(DFT)
    for ai in s.universe
        balance(s)
    end
end

include("adhoc/balance.jl")

export BalanceStatus, TotalBalance, FreeBalance, UsedBalance
export balance, balance!
