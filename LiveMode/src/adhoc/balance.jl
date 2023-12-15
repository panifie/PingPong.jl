using .Lang: splitkws, @get

function _fetch_balance(exc::Exchange{ExchangeID{:bybit}}, args...; type=:swap, params=pydict(), kwargs...)
    params["type"] = @pystr(type, lowercase(string(type)))
    pyfetch(_exc_balance_func(exc), args...; params, kwargs...)
end

function _fetch_balance(
    exc::Exchange{ExchangeID{:phemex}}, args...; type=:swap, code="", params=pydict(), kwargs...
)
    params["type"] = @pystr type lowercase(string(type))
    params["code"] = @pystr code uppercase(string(code))

    pyfetch(
        _exc_balance_func(exc), args...; params, kwargs...
    )
end
