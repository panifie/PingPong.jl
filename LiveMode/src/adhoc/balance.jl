using .Lang: splitkws, @get

function _fetch_balance(exc::Exchange{ExchangeID{:bybit}}, qc, syms, args...; type=:swap, params=pydict(), kwargs...)
    params["type"] = @pystr(type, lowercase(string(type)))
    pyfetch(_exc_balance_func(exc), args...; params, kwargs...)
end

function _fetch_balance(
    exc::Exchange{ExchangeID{:phemex}}, qc, syms, args...; type=:swap, code=nothing, params=pydict(), kwargs...
)
    params["type"] = @pystr type lowercase(string(type))
    params["code"] = @pystr code uppercase(string(@something code qc))

    pyfetch(
        _exc_balance_func(exc); params, kwargs...
    )
end
