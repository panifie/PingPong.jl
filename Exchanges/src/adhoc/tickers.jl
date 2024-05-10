function fetch_tickers(exc::Exchange, type)
    @assert hastickers(exc) "Exchange doesn't provide tickers list."
    f = first(exc, :fetchTickersWs, :fetchTickers)
    v = pyfetch(f; params=LittleDict(@pyconst("type") => @pystr(type)))
    if v isa Exception
        @error "fetch tickers: " exception = v
        throw(v)
    else
        v
    end
end

function syms_by_market_type(exc, type)
    tp = string(type)
    [sym for (sym, mkt) in exc.markets if mkt["type"] == tp]
end

function fetch_tickers(exc::Exchange{ExchangeID{:bitrue}}, type)
    markets = syms_by_market_type(exc, type)
    f = first(exc, :fetchTickersWs, :fetchTickers)
    v = pyfetch(f, markets; params=LittleDict(@pyconst("type") => @pystr(type)))
    if v isa Exception
        @error "fetch tickers: " exception = v
        throw(v)
    else
        v
    end
end
