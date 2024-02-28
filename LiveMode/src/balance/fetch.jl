using .Lang: @lget!, splitkws
using .ExchangeTypes
using .Exchanges: issandbox, current_account
using .Misc.TimeToLive
using .Misc: LittleDict, DFT, ZERO
using .Python: pytofloat, Py, @pystr, @pyconst, PyDict, @pyfetch, pyfetch, pyconvert
using .Instances: bc, qc
import .st: current_total, MarginStrategy, NoMarginStrategy

@doc """ Enum representing the status of a balance.

$(FIELDS)

This enum is used to represent the status of a balance in the system.
It can take one of three values: `TotalBalance`, `FreeBalance`, or `UsedBalance`.
"""
@enum BalanceStatus TotalBalance FreeBalance UsedBalance
@doc "A reference to the time-to-live duration for balance data."
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

@doc """ Fetches the balance for a given live strategy.

$(TYPEDSIGNATURES)

The function fetches the balance by calling the `_fetch_balance` function with the exchange associated with the live strategy and any additional arguments.
The balance is fetched from the exchange's API.
"""
function fetch_balance(s::LiveStrategy, args...; type=_balance_type(s), kwargs...)
    qc = nameof(s.cash)
    syms = st.assets(s)
    _fetch_balance(exchange(s), qc, syms, args...; type, kwargs...)
end

function _fetch_balance(exc, args...; kwargs...)
    pyfetch(_exc_balance_func(exc), args...; kwargs...)
end

@doc """ Updates or retrieves the balance dictionary for a given exchange.

$(TYPEDSIGNATURES)
"""
function _balancedict!(exc)
    @lget! BalanceCacheDict (exchangeid(exc), current_account(exc), issandbox(exc)) Dict{
        Tuple{BalanceStatus,Symbol},Py
    }()
end
@doc """ Updates or retrieves the symbol dictionary for a given exchange.

$(TYPEDSIGNATURES)
"""
function _symdict!(exc)
    @lget! BalanceCacheSyms (exchangeid(exc), current_account(exc), issandbox(exc)) Dict{
        Tuple{Symbol,BalanceStatus,Symbol},DFT
    }()
end
_balancetype(_, _) = Symbol()

@doc """ Fetches and caches the balance for a given exchange.

$(TYPEDSIGNATURES)

The function retrieves the balance for a specified exchange and caches it for a duration defined by `BalanceTTL[]`.
The balance is indexed by the balance status and type.
This function is useful when you need to frequently access the balance without making repeated API calls to the exchange.
"""
function balance(exc::Exchange, args...; qc=Symbol(), type=Symbol(), status=TotalBalance, kwargs...)
    d = _balancedict!(exc)
    try
        @lget! d (status, type) begin
            b = _fetch_balance(exc, qc, args...; type, kwargs...)
            b[@pystr(lowercase(string(status)))]
        end

    catch
        @debug_backtrace LogBalance
        @warn "Could not fetch balance from $(nameof(exc))"
    end
end

@doc """ Fetches and caches the balance for a specified exchange.

$(TYPEDSIGNATURES)

The function retrieves the balance for a specified exchange and caches it for a duration defined by `BalanceTTL[]`.
The balance is indexed by the balance status and type.
It is useful when you need to frequently access the balance without making repeated API calls to the exchange.

"""
function balance(
    exc::Exchange,
    sym::Union{<:AssetInstance,Symbol,String},
    args...;
    qc=Symbol(),
    type=Symbol(),
    status=TotalBalance,
    kwargs...,
)
    d = _symdict!(exc)
    k = _pystrsym(sym)
    @lget! d (Symbol(k), status, type) begin
        b = balance(exc, args...; qc, type, status, kwargs...)
        if b isa Py
            pyconvert(DFT, get_py(b, k, ZERO))
        else
            return nothing
        end
    end
end

@doc """ Fetches the balance for a specified exchange, forcefully caching it.

$(TYPEDSIGNATURES)

The function fetches the balance for a specified exchange and forcefully caches it for a duration defined by `BalanceTTL[]`.
Unlike `balance`, this function updates the cache even if the balance is already cached.
This is useful when you need to ensure that the most recent balance is used.

"""
function balance!(
    exc::Exchange, args...; raw=false, type=Symbol(), status=TotalBalance, kwargs...
)
    b = let resp = _fetch_balance(exc, args...; type, kwargs...)
        if resp isa Exception
            @debug resp _module = LogBalance
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

@doc """ Fetches the balance for a specified exchange and symbol, forcefully caching it.

$(TYPEDSIGNATURES)

This function fetches the balance for a specified exchange and symbol, and forcefully caches it for a duration defined by `BalanceTTL[]`.
Unlike `balance`, this function updates the cache even if the balance is already cached.
This is useful when you need to ensure that the most recent balance is used for a specific symbol.

"""
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

function balance(s::NoMarginStrategy{Live}, args...; type=_balance_type(s), kwargs...)
    balance(exchange(s), args...; type, kwargs...)
end

function balance(s::MarginStrategy{Live}, sym, args...; type=_balance_type(s), kwargs...)
    balance(exchange(s), sym, args...; type, kwargs...)
end

function balance!(s::NoMarginStrategy{Live}, args...; type=_balance_type(s), kwargs...)
    balance!(exchange(s), args...; type, kwargs...)
end

function balance!(s::MarginStrategy{Live}, args...; type=_balance_type(s), kwargs...) # or :margin
    balance!(exchange(s), args...; type, kwargs...)
end


export BalanceStatus, TotalBalance, FreeBalance, UsedBalance
export balance, balance!
