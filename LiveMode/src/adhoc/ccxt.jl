resp_code(resp, ::Type{ExchangeID{:bybit}}) = get_py(resp, nothing, "retCode", "ret_code")
resp_code(resp, ::Type{ExchangeID{:deribit}}) = get_py(resp, nothing, "result")
_ccxtbalance_type(::Strategy{X,N,ExchangeID{:bybit},<:WithMargin}) where {X<:ExecMode,N} = @pyconst("swap")

# NOTE: only for isolated margin
function resp_position_initial_margin(resp, ::Type{ExchangeID{:binanceusdm}})
    im = get_py(resp, Pos.initialMargin, missing)
    if isemptish(im)
        @coalesce get_py(@get_py(resp, "info", pydict()), "iw", missing) pytofloat(0.0)
    else
        im
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
