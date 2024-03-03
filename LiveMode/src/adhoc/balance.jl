using .Lang: splitkws, @get
using .Exchanges: gettimeout

_balance_type(s::Strategy{<:ExecMode,N,ExchangeID{:bybit},<:WithMargin}) where {N} = :unified
_balance_type(s::Strategy{<:ExecMode,N,ExchangeID{:bybit},NoMargin}) where {N} = :unified

function _fetch_balance(exc::Exchange{ExchangeID{:bybit}}, qc, syms, args...; timeout=gettimeout(exc), type="unified", params=pydict(), kwargs...)
    # assume bybit UTA
    params[@pyconst("type")] = "unified"
    _execfunc_timeout(_exc_balance_func(exc), args...; timeout, params, kwargs...)
end

function _fetch_balance(
    exc::Exchange{ExchangeID{:phemex}}, qc, syms, args...; timeout=gettimeout(exc), type=:swap, code=nothing, params=pydict(), kwargs...
)
    params["type"] = @pystr type lowercase(string(type))
    params["code"] = @pystr code uppercase(string(@something code qc))

    _execfunc_timeout(
        _exc_balance_func(exc); timeout, params, kwargs...
    )
end

function _fetch_balance(
    exc::Exchange{<:eids(:deribit, :gateio, :hitbtc, :binancecoin, :binance)}, qc, syms, args...; timeout=gettimeout(exc), type=:swap, code=nothing, params=pydict(), kwargs...
)
    params["code"] = @pystr code uppercase(string(@something code qc))
    if haskey(params, "type")
        delete!(params, "type")
    end

    _execfunc_timeout(
        _exc_balance_func(exc); timeout, params, kwargs...
    )
end

_parse_balance(::Exchange, v) = v

function _parse_balance(exc::Exchange{<:eids(:binanceusdm)}, v)
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
            adict = v[id] = pydict()
            adict["free"] = free_bal[id] = pytofloat(a["availableBalance"])
            adict["used"] = used_bal[id] = missing
            adict["total"] = total_bal[id] = get_py(a, "", "walletBalance") |> pytofloat
        end
        for p in positions
            id = p["symbol"]
            if haskey(markets, id)
                sym = markets[id][0]["symbol"]
                symdict = v[sym] = pydict()
                symdict["free"] = free_bal[sym] = p["positionAmt"] |> pytofloat
                symdict["used"] = used_bal[sym] = missing
                symdict["total"] = total_bal[sym] = p["isolatedWallet"] |> pytofloat
            end
        end
    catch
        @debug_backtrace LogBalance
    end
    return v
end

function _fetch_balance(
    exc::Exchange{<:eids(:binanceusdm)}, qc, syms, args...; timeout=gettimeout(exc), type=:swap, code=nothing, params=pydict(), kwargs...
)
    params["code"] = @pystr code uppercase(string(@something code qc))
    if haskey(params, "type")
        delete!(params, "type")
    end
    resp = _execfunc_timeout(
        _exc_balance_func(exc); timeout, params, kwargs...
    )
    _parse_balance(exc, resp)
end

_exc_balance_func(exc::Exchange{<:eids(:binanceusdm)}) = exc.fetchBalance # FIXME
