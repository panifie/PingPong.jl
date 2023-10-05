using .Lang: @lget!, splitkws
using .ExchangeTypes
using .Exchanges: issandbox, current_account
using .Misc.TimeToLive
using .Misc: LittleDict, DFT, ZERO
using .Python: pytofloat, Py, @pystr, @pyconst, PyDict, @pyfetch, pyfetch, pyconvert
using .Instances: bc, qc
import .st: current_total, MarginStrategy, NoMarginStrategy

@enum BalanceStatus TotalBalance FreeBalance UsedBalance
const BalanceTTL = Ref(Second(5))
const BalanceCacheDict = safettl(
    Tuple{ExchangeID,String,Bool}, Dict{Tuple{BalanceStatus,Symbol},Py}, BalanceTTL[]
)
const BalanceCacheSyms = safettl(
    Tuple{ExchangeID,String,Bool},
    Dict{Tuple{Symbol,BalanceStatus,Symbol},DFT},
    BalanceTTL[],
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

_exc_balance_func(exc) = first(exc, :fetchBalanceWs, :fetchBalance)

function fetch_balance(s::LiveStrategy, args...; kwargs...)
    _fetch_balance(exchange(s), args...; kwargs...)
end

function _fetch_balance(exc, args...; kwargs...)
    pyfetch(_exc_balance_func(exc), args...; (splitkws(:type; kwargs).rest)...)
end
function _balancedict!(exc)
    @lget! BalanceCacheDict (exchangeid(exc), current_account(exc), issandbox(exc)) Dict{
        Tuple{BalanceStatus,Symbol},Py
    }()
end
function _symdict!(exc)
    @lget! BalanceCacheSyms (exchangeid(exc), current_account(exc), issandbox(exc)) Dict{
        Tuple{Symbol,BalanceStatus,Symbol},DFT
    }()
end
_balancetype(_, _) = Symbol()

@doc "Fetch balance, caching for $(BalanceTTL[])"
function balance(exc::Exchange, args...; type=Symbol(), status=TotalBalance, kwargs...)
    d = _balancedict!(exc)
    try
        @lget! d (status, type) begin
            b = _fetch_balance(exc, args...; type, kwargs...)
            b[@pystr(lowercase(string(status)))]
        end

    catch
        @debug_backtrace
        @warn "Could not fetch balance from $(nameof(exc))"
    end
end

@doc "Fetch balance for symbol, caching for $(BalanceTTL[])."
function balance(
    exc::Exchange,
    sym::Union{<:AssetInstance,Symbol,String},
    args...;
    type=Symbol(),
    status=TotalBalance,
    kwargs...,
)
    d = _symdict!(exc)
    k = _pystrsym(sym)
    @lget! d (Symbol(k), status, type) begin
        b = balance(exc, args...; type, status, kwargs...)
        if b isa Py
            pyconvert(DFT, get_py(b, k, ZERO))
        else
            return nothing
        end
    end
end

@doc "Fetch balance forcefully, caching for $(BalanceTTL[])."
function balance!(
    exc::Exchange, args...; raw=false, type=Symbol(), status=TotalBalance, kwargs...
)
    b = let resp = _fetch_balance(exc, args...; type, kwargs...)
        if resp isa Exception
            @debug resp
        else
            resp[@pystr(lowercase(string(status)))]
        end
    end
    if isnothing(b)
        @warn "Failed to fetch balance from $(nameof(exc)) $args"
        return nothing
    end
    d = _balancedict!(exc)
    if b isa Py
        d[(status, type)] = b
        empty!(_symdict!(exc))
        raw ? b : pyconvert(Dict{Symbol,DFT}, b)
    end
end

@doc "Fetch balance forcefully for symbol, caching for $(BalanceTTL[])."
function balance!(
    exc::Exchange,
    sym::Union{<:AssetInstance,String,Symbol},
    args...;
    type=Symbol(),
    status=TotalBalance,
    kwargs...,
)
    try
        b = balance!(exc, args...; type, status, kwargs...)
        d = _symdict!(exc)
        k = _pystrsym(sym)
        v = pyconvert(DFT, get(b, Symbol(k), ZERO))
        d[(Symbol(k), status, type)] = v
        pyconvert(DFT, v)

    catch
        @warn "Could not fetch balance from $(nameof(exc))"
    end
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


export BalanceStatus, TotalBalance, FreeBalance, UsedBalance
export balance, balance!
