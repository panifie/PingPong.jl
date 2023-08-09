using .Lang: splitkws
const _bybitBalanceTypes2 = Dict{Symbol,PyDict}()
function _fetch_balance(exc::Exchange{ExchangeID{:bybit}}, args...; type=:spot, kwargs...)
    tp = @lget! _bybitBalanceTypes2 type PyDict(
        LittleDict("type" => lowercase(String(type)))
    )
    pyfetch(exc.py.fetchBalance, (args..., tp)...; splitkws(:code; kwargs)[2]...)
end

const _phemexBalanceTypes1 = Dict{Symbol,PyDict}()
function _fetch_balance(
    exc::Exchange{ExchangeID{:phemex}}, args...; type=:swap, code="", kwargs...
)
    tp = @lget! _bybitBalanceTypes2 type PyDict(
        LittleDict("type" => lowercase(string(type)), "code" => uppercase(string(code)))
    )

    pyfetch(exc.py.fetchBalance, (args..., tp)...; kwargs...)
end
