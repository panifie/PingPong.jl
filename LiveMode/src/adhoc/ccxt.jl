resp_code(resp, ::Type{ExchangeID{:bybit}}) = get_py(resp, nothing, "retCode", "ret_code")
resp_code(resp, ::Type{ExchangeID{:deribit}}) = get_py(resp, nothing, "result")
_ccxtbalance_type(::Strategy{X,N,ExchangeID{:bybit},<:WithMargin}) where {X<:ExecMode,N} = @pyconst("swap")

function resp_position_initial_margin(resp, ::Type{ExchangeID{:binanceusdm}})
    im = get_py(resp, Pos.initialMargin, missing)
    if isemptish(im)
        @coalesce get_py(@get_py(resp, "info", pydict()), "iw", missing) pyfloat()
    else
        im
    end |> pytofloat
end
