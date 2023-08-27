# using ExchangeTypes: has

function dosetmargin(exc::Exchange{ExchangeID{:phemex}}, mode_str, symbol)
    pyfetch(exc.setPositionMode, false, symbol) # hedged mode to false
    has(exc, :watchPositions) && @warn "phemex supports watchPositions"
    has(exc, :fetchPosition) && @warn "phemex supports fetchPosition"
    settle = let mkt = get(exc.markets, symbol, nothing)
        @assert !isnothing(mkt) "Symbol $symbol not found in exchange markets $(nameof(exc))"
        settle = get(mkt, "settle", nothing)
        @assert !isnothing(settle) "Symbol does not have a settle currency"
        settle
    end
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
    this_lev = @something this_lev 1.0
    lev = if mode_str == "cross"
        Base.negate(abs(this_lev))
    elseif mode_str == "isolated"
        abs(this_lev)
    else
        error("Margin mode $mode_str is not valid [supported: 'cross', 'isolated']")
    end
    resp = pyfetch(exc.setLeverage, lev, symbol)
    resp isa PyException && return resp
    Bool(get(resp, "code", @pyconst("1")) == @pyconst("0"))
end

function leverage!(exc::Exchange{ExchangeID{:bybit}}, v::Real, sym::AbstractString)
    resp = pyfetch_timeout(exc.setLeverage, Returns(nothing), Second(3), v, sym)
    isnothing(resp) && return false
    _handle_leverage(resp)
end
