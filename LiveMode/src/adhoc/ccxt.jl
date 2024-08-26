resp_code(resp, ::Type{ExchangeID{:bybit}}) = get_py(resp, nothing, "retCode", "ret_code")
resp_code(resp, ::Type{ExchangeID{:deribit}}) = get_py(resp, nothing, "result")

# NOTE: only for isolated margin
function resp_position_initial_margin(resp, ::Type{ExchangeID{:binanceusdm}})
    im = get_py(resp, Pos.initialMargin, 0.0)
    if pytruth(im)
        im
    else
        @coalesce get_py(@get_py(resp, "info", pydict()), "iw", missing) im
    end |> pytofloat
end

function _ccxt_balance_args(::Strategy{<:ExecMode,ExchangeID{:binance}}, kwargs)
    params, rest = split_params(kwargs)
    for k in ("type", "code")
        if haskey(params, k)
            delete!(params, k)
        end
    end
    (; params, rest)
end

function balance_type(s::Strategy{<:ExecMode,N,ExchangeID{:phemex},<:WithMargin} where {N})
    attr(s, :balance_type, :swap)
end
