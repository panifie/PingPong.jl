using .Lang: @lget!, splitkws
using .ExchangeTypes
using .Exchanges: issandbox, current_account
using .Misc.TimeToLive
using .Misc: LittleDict, DFT, ZERO
using .Python: pytofloat, Py, @pystr, @pyconst, PyDict, pyfetch, pyconvert
using .Instances: bc, qc
import .st: current_total, MarginStrategy, NoMarginStrategy

_exc_balance_func(exc::Exchange) = first(exc, :fetchBalanceWs, :fetchBalance)

@doc """ Fetches the balance for a given live strategy.

$(TYPEDSIGNATURES)

The function fetches the balance by calling the `_fetch_balance` function with the exchange associated with the live strategy and any additional arguments.
The balance is fetched from the exchange's API.
"""
function fetch_balance(s::LiveStrategy, args...; type=balance_type(s), kwargs...)
    qc = nameof(s.cash)
    syms = st.assets(s)
    _fetch_balance(exchange(s), qc, syms, args...; type, kwargs...)
end

function _fetch_balance(exc::Exchange, args...; timeout=gettimeout(exc), kwargs...)
    _execfunc_timeout(_exc_balance_func(exc), args...; timeout, kwargs...)
end

_fetch_balance(exc::Exchange, qc; kwargs...) = _fetch_balance(exc, qc, (); kwargs...)
