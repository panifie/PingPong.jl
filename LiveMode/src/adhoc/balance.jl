using .Lang: splitkws, @get

_balance_type(s::Strategy{<:ExecMode,N,ExchangeID{:bybit},<:WithMargin}) where {N} = :unified
_balance_type(s::Strategy{<:ExecMode,N,ExchangeID{:bybit},NoMargin}) where {N} = :unified

function _fetch_balance(exc::Exchange{ExchangeID{:bybit}}, qc, syms, args...; type="unified", params=pydict(), kwargs...)
    # assume bybit UTA
    params[@pyconst("type")] = "unified"
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

function _fetch_balance(
    exc::Exchange{<:eids(:deribit, :gateio)}, qc, syms, args...; type=:swap, code=nothing, params=pydict(), kwargs...
)
    params["code"] = @pystr code uppercase(string(@something code qc))
    if haskey(params, "type")
        delete!(params, "type")
    end

    pyfetch(
        _exc_balance_func(exc); params, kwargs...
    )
end
