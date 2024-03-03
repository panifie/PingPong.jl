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
    exc::Exchange{<:eids(:deribit, :gateio, :hitbtc, :binancecoin, :binance)}, qc, syms, args...; type=:swap, code=nothing, params=pydict(), kwargs...
)
    params["code"] = @pystr code uppercase(string(@something code qc))
    if haskey(params, "type")
        delete!(params, "type")
    end

    pyfetch(
        _exc_balance_func(exc); params, kwargs...
    )
end

function _fetch_balance(
    exc::Exchange{<:eids(:binanceusdm)}, qc, syms, args...; type=:swap, code=nothing, params=pydict(), kwargs...
)
    params["code"] = @pystr code uppercase(string(@something code qc))
    if haskey(params, "type")
        delete!(params, "type")
    end

    v = pyfetch(
        _exc_balance_func(exc); params, kwargs...
    )
    get_dict(k) =
        if !haskey(v, k) || pyisnone(v[k])
            v[k] = pydict()
        else
            v[k]
        end
    try
        assets = v["info"]["assets"]
        positions = v["info"]["positions"]
        free_bal = get_dict("free")
        used_bal = get_dict("used")
        total_bal = get_dict("total")
        markets = exc.markets_by_id
        for a in assets
            id = a["asset"]
            free_bal[id] = pytofloat(a["availableBalance"])
            used_bal[id] = missing
            total_bal[id] = get_py(a, "", "walletBalance") |> pytofloat
        end
        for p in positions
            id = p["symbol"]
            if haskey(markets, id)
                sym = markets[id][0]["symbol"]
                free_bal[sym] = p["positionAmt"] |> pytofloat
                used_bal[sym] = missing
                total_bal[sym] = p["isolatedWallet"] |> pytofloat
            end
        end
    catch
        @debug_backtrace LogBalance
    end
    Main.bal = v
    v
end

_exc_balance_func(exc::Exchange{<:eids(:binanceusdm)}) = exc.fetchBalance # FIXME
