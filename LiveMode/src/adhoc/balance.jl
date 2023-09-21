using .Lang: splitkws, @get

function _fetch_balance(exc::Exchange{ExchangeID{:bybit}}, args...; type=:swap, kwargs...)
    params = @get kwargs :params pydict()
    params[@pystr("type")] = @pystr(type, lowercase(string(type)))
    pyfetch(_exc_balance_func(exc), args...; params, splitkws(:params; kwargs).rest...)
end

function _fetch_balance(
    exc::Exchange{ExchangeID{:phemex}}, args...; type=:swap, code="", kwargs...
)
    params = @get kwargs :params pydict()
    params[@pystr("type")] = @pystr type lowercase(string(type))
    params[@pystr("code")] = @pystr code uppercase(string(code))

    pyfetch(
        _exc_balance_func(exc), args...; params, splitkws(:code, :params; kwargs).rest...
    )
end
