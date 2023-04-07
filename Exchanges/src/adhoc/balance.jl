
const _bybitBalanceTypes2 = Dict{Symbol, PyDict}()
function _fetch_balance(exc::Exchange{ExchangeID{:bybit}}, args...; type=:spot, kwargs...)
    tp = @lget! _bybitBalanceTypes2 type PyDict(Dict("type" => lowercase(String(type))))
    pyfetch(exc.py.fetchBalance, (args..., tp)...; kwargs...)
end
