using Lang: @lget!, splitkws

@enum BalanceStatus TotalBalance FreeBalance UsedBalance
const BalanceTTL = Ref(Second(5))
const BalanceCacheDict4 = TTL{ExchangeID,Dict{Tuple{BalanceStatus,Symbol},Py}}(BalanceTTL[])
const BalanceCacheSyms6 = TTL{ExchangeID,Dict{Tuple{Symbol,BalanceStatus,Symbol},Float64}}(
    BalanceTTL[]
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
        b[@pystr(string(status))]
    end
end

@doc "Fetch balance for symbol, caching for $(BalanceTTL[])."
function balance(
    exc::Exchange, sym::Symbol, args...; type=Symbol(), status=TotalBalance, kwargs...
)
    d = _symdict!(exc)
    @lget! d (sym, status, type) begin
        b = balance(exc, args...; type, status, kwargs...)
        pyconvert(Float64, b[@pystr(string(sym))])
    end
end

@doc "Fetch balance forcefully, caching for $(BalanceTTL[])."
function balance!(exc::Exchange, args...; type=Symbol(), status=TotalBalance, kwargs...)
    b = _fetch_balance(exc, args...; type, kwargs...)[@pystr(string(status))]
    d = _balancedict!(exc)
    d[(status, type)] = b
    empty!(_symdict!(exc))
    b
end

@doc "Fetch balance forcefully for symbol, caching for $(BalanceTTL[])."
function balance!(
    exc::Exchange, sym::Symbol, args...; type=Symbol(), status=TotalBalance, kwargs...
)
    b = balance!(exc, args...; type, status, kwargs...)
    d = _symdict!(exc)
    v = pyconvert(Float64, b[@pystr(string(sym))])
    d[(sym, status, type)] = v
    v
end

include("adhoc/balance.jl")

export BalanceStatus, TotalBalance, FreeBalance, UsedBalance
export balance, balance!
