using .Python: pytask

_lev_frompos(exc, symbol, settle) = begin
    pos = pyfetch(exc.fetchPositions; params=LittleDict(("settle",), (settle,)))
    pos isa PyException && return pos
    this_lev = nothing
    for item in pos
        item_sym = get(item, "symbol", @pyconst(""))
        if Bool(item_sym == @pystr(symbol))
            this_lev = pytofloat(get(item, "leverage", nothing))
            break
        end
    end
    @something this_lev 1.0
end

_settle_from_market(exc, symbol) = begin
    mkt = get(exc.markets, symbol, nothing)
    @assert !isnothing(mkt) "Symbol $symbol not found in exchange markets $(nameof(exc))"
    settle = get(mkt, "settle", nothing)
    @assert !isnothing(settle) "Symbol does not have a settle currency"
    settle
end

_negative_lev_if_cross(mode_str, lev) =
    if mode_str == "cross"
        Base.negate(abs(lev))
    elseif mode_str == "isolated"
        abs(lev)
    else
        error("Margin mode $mode_str is not valid [supported: 'cross', 'isolated']")
    end


function dosetmargin(exc::Exchange{ExchangeID{:phemex}}, mode_str, symbol;
    hedged=false, settle=_settle_from_market(exc, symbol), lev=_lev_frompos(exc, symbol, settle)
)
    task = pytask(exc.setPositionMode, hedged, symbol) # set hedged mode
    this_lev = _negative_lev_if_cross(mode_str, lev)
    resp = pyfetch(exc.setLeverage, this_lev, symbol)
    if resp isa PyException
        return resp
    end
    wait(task)
    resptobool(exc, resp)
end

function dosetmargin(exc::Exchange{ExchangeID{:bybit}}, mode_str, symbol;
    hedged=false, settle=_settle_from_market(exc, symbol), lev=_lev_frompos(exc, symbol, settle)
)
    @sync begin
        if has(exc, :setPositionMode)
            @async pyfetch(exc.setPositionMode, hedged, symbol) # hedged mode to false
        end
        resp = pyfetch(exc.setMarginMode, mode_str, symbol, params=LittleDict(("leverage",), (lev,)))
        if resp isa PyException
            msg = string(resp.v.args)
            # mode unchanged, avoid liquidation
            return if occursin(r"(110026)|(110011)", msg)
                true
            else
                resp
            end
        else
            Bool(get(resp, "retCode", @pyconst("1")) == @pyconst("0"))
        end
    end
end

leverage_value(::Exchange{ExchangeID{:phemex}}, val, sym) = round(float(val), digits=2)
leverage_value(::Exchange{<:eids(:binance, :binanceusdm, :binancecoin)}, val, sym) = round(Int, float(val))

function _handle_leverage(e::Exchange{<:eids(:binance, :binanceusdm, :binancecoin)}, resp)
    if resp isa PyException
        @debug resp
        false
    else
        haskey(resp, "leverage")
    end
end

marginmode!(exc::Exchange{<:ExchangeID{:binance}}, mode, symbol; hedged=false, kwargs...) = begin
    # setting default margin mode in the binance spot testnet triggers ccxt to
    # use wrong api endpoints
    if !issandbox(exc)
        invoke(marginmode!, Tuple{Exchange,<:Any,<:Any}, exc, mode, symbol)
    else
        return true
    end
end
