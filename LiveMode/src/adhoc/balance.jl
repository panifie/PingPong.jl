using .Lang: splitkws, @get

function _ccxt_balance_args(s::Strategy{<:ExecMode, N, ExchangeID{:phemex}}, kwargs) where {N}
    params, rest = split_params(kwargs)
    @lget! params "type" @pystr(balance_type(s))
    if s.qc == :USDT
        params["settle"] = @pyconst("USDT")
    end
    (; params, rest)
end

function balance_type(s::Strategy{<:ExecMode,N,ExchangeID{:bybit},<:WithMargin}) where {N}
    attr(s, :balance_type, :unified)
end
balance_type(s::Strategy{<:ExecMode,N,ExchangeID{:bybit},NoMargin}) where {N} = attr(s, :balance_type, :unified)
function balance_type(
    s::Strategy{<:ExecMode,N,ExchangeID{:binanceusdm},<:WithMargin}
) where {N}
    attr(s, :balance_type, :future)
end

function _fetch_balance(
    exc::Exchange{ExchangeID{:bybit}},
    qc,
    syms,
    args...;
    timeout=gettimeout(exc),
    type=:unified,
    params=pydict(),
    kwargs...,
)
    # assume bybit UTA
    params[@pyconst("type")] = @pystr type lowercase(string(type))
    _execfunc_timeout(_exc_balance_func(exc), args...; timeout, params, kwargs...)
end

function _fetch_balance(
    exc::Exchange{ExchangeID{:phemex}},
    qc,
    syms,
    args...;
    timeout=gettimeout(exc),
    type=:swap,
    code=nothing,
    params=pydict(),
    kwargs...,
)
    params[@pyconst("type")] = @pystr type lowercase(string(type))
    if type != :spot
        params["code"] = @pystr code uppercase(string(@something code qc))
    end

    _execfunc_timeout(_exc_balance_func(exc); timeout, params, kwargs...)
end

function _fetch_balance(
    exc::Exchange{<:eids(:deribit, :gateio, :hitbtc, :binancecoin)},
    qc,
    syms,
    args...;
    timeout=gettimeout(exc),
    type=:swap,
    code=nothing,
    params=pydict(),
    kwargs...,
)
    params["code"] = @pystr code uppercase(string(@something code qc))
    if haskey(params, "type")
        delete!(params, "type")
    end

    _execfunc_timeout(_exc_balance_func(exc); timeout, params, kwargs...)
end

function _fetch_balance(
    exc::Exchange{<:eids(:binance)},
    qc,
    syms,
    args...;
    timeout=gettimeout(exc),
    type=:swap,
    code=nothing,
    params=pydict(),
    kwargs...,
)
    for k in ("code", "type")
        if haskey(params, k)
            delete!(params, k)
        end
    end

    _execfunc_timeout(_exc_balance_func(exc); timeout, params, kwargs...)
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
    exc::Exchange{<:eids(:binanceusdm)},
    qc,
    syms,
    args...;
    timeout=gettimeout(exc),
    type=:future,
    code=nothing,
    params=pydict(),
    kwargs...,
)
    @lget! params "type" lowercase(string(type))
    resp = _execfunc_timeout(_exc_balance_func(exc); timeout, params, kwargs...)
    _parse_balance(exc, resp)
end

_exc_balance_func(exc::Exchange{<:eids(:binanceusdm)}) = exc.fetchBalance # FIXME

function fetch_balance(s::Strategy{Live,<:Any,<:ExchangeID{:phemex}}, args...; kwargs...)
    resp = invoke(fetch_balance, Tuple{LiveStrategy}, s, args...; kwargs...)
    w = attr(s, :live_positions_watcher, nothing)
    if !isnothing(w)
        positions = _phemex_parse_positions(s, resp)
        tasks = attr(w, :process_tasks, nothing)
        if !isemptish(positions) && !isnothing(tasks)
            t = @async begin
                pushnew!(w, positions)
                process!(w; fetched=true)
            end
            push!(tasks, t)
        end
    end
    return resp
end
