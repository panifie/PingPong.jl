using .Lang: @ifdebug
using .Python: @pystr, @pyconst
using .Python.PythonCall: pyisint, PyDict
using .OrderTypes
using .Misc: IsolatedMargin, CrossMargin, NoMargin
using .Misc.Mocking: Mocking, @mock
const ot = OrderTypes

_execfunc(f::Py, args...; kwargs...) = @mock pyfetch(f, args...; kwargs...)
_execfunc_timeout(f::Py, args...; timeout, kwargs...) = @mock pyfetch_timeout(f, Returns(missing), timeout, args...; kwargs...)
# Native functions shouldn't require a timeout
_execfunc(f::Function, args...; kwargs...) = @mock f(args...; kwargs...)

@doc "Converts a Python object to a string."
pytostring(v) = pytruth(v) ? string(v) : ""
@doc "Get the value of a Python container by key."
get_py(v::Union{Py,PyDict}, k) = get(v, @pystr(k), pybuiltins.None)
@doc "Get the value of a Python container by key, with a default value."
get_py(v::Union{Py,PyDict}, k, def) = get(v, @pystr(k), def)
@doc "Get the value of a Python container by multiple keys."
get_py(v::Union{Py,PyDict}, def, keys::Vararg{String}) = begin
    for k in keys
        ans = get_py(v, k)
        pyisnone(ans) || (return ans)
    end
    return def
end
macro get_py(v, k, def)
    e = quote
        @get $v @pystr($k) $def
    end
    esc(e)
end

@doc "Get value of key as a string."
get_string(v::Union{Py,PyDict}, k) = get_py(v, k) |> pytostring
@doc "Get value of key as a float."
get_float(v::Union{Py,PyDict}, k) = get_py(v, k) |> pytofloat
@doc "Get value of key as a boolean."
get_bool(v::Union{Py,PyDict}, k) = get_py(v, k) |> pytruth

_option_float(o::Union{Py,PyDict}, k; nonzero=false) =
    let v = get_py(o, k)
        if pyisinstance(v, pybuiltins.float)
            ans = pytofloat(v)
            if nonzero && iszero(ans)
            else
                ans
            end
        end
    end

@doc """ Retrieves a float value from a Python response.

$(TYPEDSIGNATURES)

This function retrieves a float value from a Python response `resp` for a given key `k`. If the key isn't found, it returns a default value `def`. If the key is found and the retrieved value isn't approximately equal to `def`, it logs a warning and returns the retrieved value.

"""
function get_float(resp::Union{Py,PyDict}, k, def, args...; ai)
    v = _option_float(resp, k)
    if isnothing(v)
        def
    else
        ismissing(def) ||
            isapprox(ai, v, def, args...) ||
            begin
                @warn "Exchange order $k not matching request $def (local),  $v ($(nameof(exchange(ai))))"
            end
        v
    end
end

@doc "Get the timestamp from a Python object, by accessing the first of key available."
get_timestamp(py, keys=("lastUpdateTimestamp", "timestamp")) =
    for k in keys
        v = get_py(py, k)
        pyisnone(v) || return v
    end

_tryasdate(py) = tryparse(DateTime, rstrip(string(py), 'Z'))
pytodate(py::Union{Py,PyDict}) = pytodate(py, "lastUpdateTimestamp", "timestamp")
@doc "Convert a Python object to a date."
function pytodate(py::Union{Py,PyDict}, keys...)
    let v = get_timestamp(py, keys)
        if pyisinstance(v, pybuiltins.str)
            _tryasdate(v)
        elseif pyisinstance(v, pybuiltins.int)
            pyconvert(Int, v) |> dt
        elseif pyisinstance(v, pybuiltins.float)
            pyconvert(DFT, v) |> dt
        end
    end
end
pytodate(py::Union{Py,PyDict}, ::EIDType, args...; kwargs...) = pytodate(py, args...; kwargs...)
@doc "Convert a Python object to a date, defaulting to `now()`."
get_time(v::Union{Py,PyDict}, keys...) = @something pytodate(v, keys...) now()

_pystrsym(v::String) = @pystr(uppercase(v))
_pystrsym(v::Symbol) = @pystr(uppercase(string(v)))
_pystrsym(ai::AssetInstance) = @pystr(ai.bc)

_ccxtordertype(::LimitOrder) = @pyconst "limit"
_ccxtordertype(::MarketOrder) = @pyconst "market"
_ccxtorderside(::BySide{Buy}) = @pyconst "buy"
_ccxtorderside(::BySide{Sell}) = @pyconst "sell"
_ccxtobside(::BySide{Buy}) = @pyconst "bids"
_ccxtobside(::BySide{Sell}) = @pyconst "asks"
_ccxtorderside(::Union{AnyBuyOrder,Type{<:AnyBuyOrder}}) = @pyconst "buy"
_ccxtorderside(::Union{AnySellOrder,Type{<:AnySellOrder}}) = @pyconst "sell"
_ccxtmarginmode(::IsolatedMargin) = @pyconst "isolated"
_ccxtmarginmode(::NoMargin) = pybuiltins.None
_ccxtmarginmode(::CrossMargin) = @pyconst "cross"
_ccxtmarginmode(v) = marginmode(v) |> _ccxtmarginmode

@doc "Convert a ccxt order type to a LiveMode order type."
ordertype_fromccxt(resp, eid::EIDType) =
    let v = resp_order_type(resp, eid)
        if pyeq(Bool, v, @pyconst "market")
            ot.MarketOrderType
        elseif pyeq(Bool, v, @pyconst "limit")
            ordertype_fromtif(resp, eid)
        else
            # when CCXT doesn't fill the order type
            # we use the type from our side of the request
            nothing
        end
    end

@doc "Convert a PingPong order type to a ccxt time-in-force string."
function _ccxttif(exc, type)
    if type <: AnyPostOnlyOrder
        @assert has(exc, :createPostOnlyOrder) "Exchange $(nameof(exc)) doesn't support post only orders."
        "PO"
    elseif type <: AnyGTCOrder
        "GTC"
    elseif type <: AnyFOKOrder
        "FOK"
    elseif type <: AnyIOCOrder
        "IOC"
    elseif type <: AnyMarketOrder
        ""
    else
        @warn "Unable to choose time-in-force setting for order type $type (defaulting to GTC)."
        "GTC"
    end
end

@doc "Convert a ccxt time-in-force string to a PingPong order type."
ordertype_fromtif(o::Py, eid::EIDType) =
    let tif = resp_order_tif(o, eid)
        if pyeq(Bool, tif, @pyconst("PO"))
            ot.PostOnlyOrderType
        elseif pyeq(Bool, tif, @pyconst("GTC"))
            ot.GTCOrderType
        elseif pyeq(Bool, tif, @pyconst("FOK"))
            ot.FOKOrderType
        elseif pyeq(Bool, tif, @pyconst("IOC"))
            ot.IOCOrderType
        end
    end

@doc "Convert a ccxt order side to a PingPong order side."
_orderside(o::Union{Py,PyDict}, eid) =
    let v = resp_order_side(o, eid)
        if pyeq(Bool, v, @pyconst("buy"))
            Buy
        elseif pyeq(Bool, v, @pyconst("sell"))
            Sell
        end
    end

@doc "Get the order id from a ccxt order object as a string."
_orderid(o::Union{Py,PyDict}, eid::EIDType) =
    let v = resp_order_id(o, eid)
        if pyisinstance(v, pybuiltins.str)
            return string(v)
        else
            v = resp_order_clientid(o, eid)
            if pyisinstance(v, pybuiltins.str)
                return string(v)
            end
        end
    end

function _checkordertype(exc, sym)
    @assert has(exc, sym) "Exchange $(nameof(exc)) doesn't support $sym orders."
end

@doc "Get the ccxt order type string from a PingPong order type."
function _ccxtordertype(exc, type)
    @pystr if type <: AnyLimitOrder
        _checkordertype(exc, :createLimitOrder)
        "limit"
    elseif type <: AnyMarketOrder
        _checkordertype(exc, :createMarketOrder)
        "market"
    else
        error("Order type $type is not valid.")
    end
end

@doc "Get the ccxt exchange specific time-in-force value."
time_in_force_value(::Exchange, v) = v
@doc "Get the ccxt exchange specific time-in-force key."
time_in_force_key(::Exchange) = "timeInForce"

@doc "Tests if a ccxt order object is filled."
function _ccxtisfilled(resp::Union{Py,PyDict}, ::EIDType)
    get_float(resp, "filled") == get_float(resp, "amount") &&
        iszero(get_float(resp, "remaining"))
end

@doc "Tests if a ccxt order object is synced by comparing filled amount and trades."
function isorder_synced(o, ai, resp::Union{Py,PyDict}, eid::EIDType=exchangeid(ai))
    @debug "is order synced:" _module = LogSyncOrder filled_amount(o) resp_order_filled(resp, eid) resp_order_trades(resp, eid)
    order_filled = resp_order_filled(resp, eid)
    v = isapprox(ai, filled_amount(o), order_filled, Val(:amount)) ||
        let ntrades = length(resp_order_trades(resp, eid))
        order_trades = trades(o)
        if ntrades > 0
            ntrades == length(order_trades)
        elseif length(order_trades) > 0
            amt = sum(t.amount for t in order_trades)
            isapprox(ai, amt, order_filled, Val(:amount))
        else
            false
        end
    end
    @debug "is order synced:" _module = LogSyncOrder v
    return v
end

@doc "Determine the PingPong order side from a ccxt order object."
function _ccxt_sidetype(
    resp, eid::EIDType; o=nothing, getter=resp_trade_side, def::Type{<:OrderSide}=Sell
)::Type{<:OrderSide}
    side = getter(resp, eid)
    if pyeq(Bool, side, @pyconst("buy"))
        Buy
    elseif pyeq(Bool, side, @pyconst("sell"))
        Sell
    elseif applicable(orderside, o)
        orderside(o)
    else
        def
    end
end

_ccxtisstatus(status::String, what) = pyeq(Bool, @pystr(status), @pystr(what))
_ccxtisstatus(resp, statuses::Vararg{String}) = any(x -> _ccxtisstatus(resp, x), statuses)
function _ccxtisstatus(resp, status::String, eid::EIDType)
    pyeq(Bool, resp_order_status(resp, eid), @pystr(status))
end
@doc "Tests if a ccxt order object is open."
_ccxtisopen(resp, eid::EIDType) = pyeq(Bool, resp_order_status(resp, eid), @pyconst("open"))
@doc "Tests if a ccxt order object is closed."
function _ccxtisclosed(resp, eid::EIDType)
    pyeq(Bool, resp_order_status(resp, eid), @pyconst("closed"))
end

@doc "The ccxt balance type to use depending on the strategy."
_ccxtbalance_type(::NoMarginStrategy) = @pyconst("spot")
_ccxtbalance_type(::MarginStrategy) = @pyconst("futures")

resp_trade_cost(resp, ::EIDType)::DFT = get_float(resp, "cost")
resp_trade_amount(resp, ::EIDType)::DFT = get_float(resp, Trf.amount)
resp_trade_amount(resp, ::EIDType, ::Type{Py}) = get_py(resp, Trf.amount)
resp_trade_price(resp, ::EIDType)::DFT = get_float(resp, Trf.price)
resp_trade_price(resp, ::EIDType, ::Type{Py}) = get_py(resp, Trf.price)
resp_trade_timestamp(resp, ::EIDType) = get_py(resp, Trf.timestamp, @pyconst(0))
resp_trade_timestamp(resp, ::EIDType, ::Type{DateTime}) = get_time(resp)
resp_trade_symbol(resp, ::EIDType) = get_py(resp, Trf.symbol, @pyconst(""))
resp_trade_id(resp, ::EIDType) = get_py(resp, Trf.id, @pyconst(""))
resp_trade_side(resp, ::EIDType) = get_py(resp, Trf.side)
resp_trade_fee(resp, ::EIDType) = get_py(resp, Trf.fee)
resp_trade_fees(resp, ::EIDType) = get_py(resp, Trf.fees)
resp_trade_order(resp, ::EIDType) = get_py(resp, Trf.order)
resp_trade_order(resp, ::EIDType, ::Type{String}) = get_py(resp, Trf.order) |> pytostring
resp_trade_type(resp, ::EIDType) = get_py(resp, Trf.type)
resp_trade_tom(resp, ::EIDType) = get_py(resp, Trf.takerOrMaker)
resp_trade_info(resp, ::EIDType) = get_py(resp, "info")

resp_order_remaining(resp, ::EIDType)::DFT = get_float(resp, "remaining")
resp_order_remaining(resp, ::EIDType, ::Type{Py}) = get_py(resp, "remaining")
resp_order_filled(resp, ::EIDType)::DFT = get_float(resp, "filled")
resp_order_filled(resp, ::EIDType, ::Type{Py}) = get_py(resp, "filled")
resp_order_cost(resp, ::EIDType)::DFT = get_float(resp, "cost")
resp_order_cost(resp, ::EIDType, ::Type{Py}) = get_py(resp, "cost")
resp_order_average(resp, ::EIDType)::DFT = get_float(resp, "average_price")
resp_order_average(resp, ::EIDType, ::Type{Py}) = get_py(resp, "average_price")
resp_order_price(resp, ::EIDType, ::Type{Py}) = get_py(resp, "price")
function resp_order_price(resp, ::EIDType, args...; kwargs...)::DFT
    get_float(resp, "price", args...; kwargs...)
end
resp_order_amount(resp, ::EIDType, ::Type{Py}) = get_py(resp, "amount")
function resp_order_amount(resp, ::EIDType, args...; kwargs...)::DFT
    get_float(resp, "amount", args...; kwargs...)
end
resp_order_trades(resp, ::EIDType) = get_py(resp, (), "trades")
resp_order_type(resp, ::EIDType) = get_py(resp, "type")
resp_order_tif(resp, ::EIDType) = get_py(resp, "timeInForce")
resp_order_lastupdate(resp, ::EIDType) = get_py(resp, "lastUpdateTimestamp")
resp_order_timestamp(resp, ::EIDType) = pytodate(resp)
resp_order_timestamp(resp, ::EIDType, ::Type{Py}) = get_py(resp, "timestamp")
resp_order_id(resp, ::EIDType) = get_py(resp, "id")
resp_order_id(resp, eid::EIDType, ::Type{String})::String =
    resp_order_id(resp, eid) |> pytostring
resp_order_clientid(resp, ::EIDType) = get_py(resp, "clientOrderId")
resp_order_symbol(resp, ::EIDType) = get_py(resp, "symbol", @pyconst(""))
resp_order_side(resp, ::EIDType) = get_py(resp, Trf.side)
resp_order_status(resp, ::EIDType) = get_py(resp, "status")
function resp_order_status(resp, eid::EIDType, ::Type{String})
    resp_order_status(resp, eid) |> pytostring
end
resp_order_loss_price(resp, ::EIDType)::Option{DFT} = _option_float(resp, "stopLossPrice", nonzero=true)
resp_order_profit_price(resp, ::EIDType)::Option{DFT} =
    _option_float(resp, "takeProfitPrice", nonzero=true)
resp_order_stop_price(resp, ::EIDType)::Option{DFT} = _option_float(resp, "stopPrice", nonzero=true)
resp_order_trigger_price(resp, ::EIDType)::Option{DFT} = _option_float(resp, "triggerPrice", nonzero=true)
resp_order_info(resp, ::EIDType) = get_py(resp, "info")

resp_position_symbol(resp, ::EIDType) = get_py(resp, Pos.symbol)
function resp_position_symbol(resp, ::EIDType, ::Type{String})
    get_py(resp, Pos.symbol) |> pytostring
end
resp_position_contracts(resp, ::EIDType)::DFT = get_float(resp, Pos.contracts)
resp_position_entryprice(resp, ::EIDType)::DFT = get_float(resp, Pos.entryPrice)
resp_position_mmr(resp, ::EIDType)::DFT = get_float(resp, "maintenanceMarginPercentage")
resp_position_side(resp, ::EIDType) = get_py(resp, @pyconst(""), Pos.side).lower()
resp_position_unpnl(resp, ::EIDType)::DFT = get_float(resp, Pos.unrealizedPnl)
resp_position_leverage(resp, ::EIDType)::DFT = get_float(resp, Pos.leverage)
resp_position_liqprice(resp, ::EIDType)::DFT = get_float(resp, Pos.liquidationPrice)
resp_position_initial_margin(resp, ::EIDType)::DFT = get_float(resp, Pos.initialMargin)
resp_position_maintenance_margin(resp, ::EIDType)::DFT =
    get_float(resp, Pos.maintenanceMargin)
resp_position_collateral(resp, ::EIDType)::DFT = get_float(resp, Pos.collateral)
resp_position_notional(resp, ::EIDType)::DFT = get_float(resp, Pos.notional)
resp_position_lastprice(resp, ::EIDType)::DFT = get_float(resp, Pos.lastPrice)
resp_position_markprice(resp, ::EIDType)::DFT = get_float(resp, Pos.markPrice)
resp_position_hedged(resp, ::EIDType)::Bool = get_bool(resp, Pos.hedged)
resp_position_timestamp(resp, ::EIDType)::DateTime = get_time(resp)
resp_position_margin_mode(resp, ::EIDType) = get_py(resp, Pos.marginMode)
resp_position_margin_mode(resp, eid::EIDType, ::Val{:parsed}) = begin
    v = resp_position_margin_mode(resp, eid)
    if pyisnone(v)
        nothing
    else
        marginmode(v)
    end
end

resp_code(resp, ::EIDType) = get_py(resp, "code")
resp_ticker_price(resp, ::EIDType, k) = get_py(resp, k)
resp_event_type(resp, eid::EIDType)::T where {T<:Type{<:ot.ExchangeEvent}} = begin
    if haskey(resp, @pyconst("clientOrderId"))
        if iszero(resp_order_amount(resp, eid))
            ot.ExchangeEvent
        else
            ot.Order
        end
    elseif haskey(resp, @pyconst("order"))
        ot.Trade
    elseif haskey(resp, @pyconst("contracts"))
        ot.PositionUpdate
    elseif haskey(resp, @pyconst("total")) &&
           haskey(resp, @pyconst("free")) &&
           haskey(resp, @pyconst("used"))
        ot.Balance
    elseif islist(resp) &&
           !isempty(resp) && let v = first(resp)
               pyisint(first(v)) &&
                   length(v) == 6
           end
        ot.OHLCV
    end
end
