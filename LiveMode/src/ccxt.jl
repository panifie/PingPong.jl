using .Lang: @ifdebug
using .Python: @pystr
using .OrderTypes
const ot = OrderTypes

_ccxtordertype(::LimitOrder) = @pystr "limit"
_ccxtordertype(::MarketOrder) = @pystr "market"
_ccxtorderside(::Type{Buy}) = @pystr "buy"
_ccxtorderside(::Type{Sell}) = @pystr "sell"
_ccxtorderside(::Union{AnyBuyOrder,Type{<:AnyBuyOrder}}) = @pystr "buy"
_ccxtorderside(::Union{AnySellOrder,Type{<:AnySellOrder}}) = @pystr "sell"

ordertype_fromccxt(resp) =
    let v = get_py(resp, "type")
        if v == @pystr "market"
            MarketOrderType
        elseif v == @pystr "limit"
            ordertype_fromtif(resp)
        end
    end

islist(v) = pyisinstance(v, pybuiltins.list)
isdict(v) = pyisinstance(v, pybuiltins.dict)

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

ordertype_fromtif(o::Py) =
    let tif = get_py(o, "timeInForce")
        if pyisTrue(tif == @pystr("PO"))
            ot.PostOnlyOrderType
        elseif pyisTrue(tif == @pystr("GTC"))
            ot.GTCOrderType
        elseif pyisTrue(tif == @pystr("FOK"))
            ot.FOKOrderType
        elseif pyisTrue(tif == @pystr("IOC"))
            ot.IOCOrderType
        end
    end

_orderside(o::Py) =
    let v = get_py(o, "side")
        if pyisTrue(v == @pystr("buy"))
            Buy
        elseif pyisTrue(v == @pystr("sell"))
            Sell
        end
    end

_orderfloat(o::Py, k) =
    let v = get_py(o, k)
        if pyisinstance(v, pybuiltins.float)
            pytofloat(v)
        end
    end

get_timestamp(py, keys=("timestamp", "lastUpdateTimestamp")) =
    for k in keys
        v = get_py(py, k)
        pyisnone(v) || return v
    end

function pytodate(py::Py, keys=("timestamp", "lastUpdateTimestamp"))
    let v = get_timestamp(py, keys)
        if pyisinstance(v, pybuiltins.str)
            _asdate(v)
        elseif pyisinstance(v, pybuiltins.int)
            pyconvert(Int, v) |> dt
        elseif pyisinstance(v, pybuiltins.float)
            pyconvert(DFT, v) |> dt
        end
    end
end

_orderid(o::Py) =
    let v = get_py(o, "id")
        if pyisinstance(v, pybuiltins.str)
            return string(v)
        else
            v = get_py(o, "clientOrderId")
            if pyisinstance(v, pybuiltins.str)
                return string(v)
            end
        end
    end

function _checkordertype(exc, sym)
    @assert has(exc, sym) "Exchange $(nameof(exc)) doesn't support $sym orders."
end

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

time_in_force_value(::Exchange, v) = v
time_in_force_key(::Exchange) = "timeInForce"

function isfilled(resp::Py)
    pyisTrue(get_py(resp, "filled") == get_py(resp, "amount")) &&
        iszero(get_float(resp, "remaining"))
end
