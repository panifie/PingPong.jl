resp_code(resp, ::Type{ExchangeID{:bybit}}) = get_py(resp, nothing, "retCode", "ret_code")
resp_code(resp, ::Type{ExchangeID{:deribit}}) = get_py(resp, nothing, "result")
_ccxtbalance_type(::Strategy{X,N,ExchangeID{:bybit},<:WithMargin}) where {X<:ExecMode,N} = @pyconst("swap")
