resp_code(resp, ::Type{ExchangeID{:bybit}}) = get_py(resp, "ret_code")
