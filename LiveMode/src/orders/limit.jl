using .Executors: AnyLimitOrder
using .PaperMode: _asdate, create_sim_limit_order

_ordertif(o::Py) =
    let tif = get_py(o, "timeInForce")
        if tif == "PO" || tif == "GTC"
            GTCOrder
        elseif tif == "FOK"
            FOKOrder
        elseif tif == "IOC"
            IOCOrder
        end
    end

_orderside(o::Py) =
    let v = get_py(o, "side")
        if v == @pystr("buy")
            Buy
        elseif v == @pystr("sell")
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

function create_live_limit_order(
    s::LiveStrategy, resp, ai::AssetInstance; t, price, amount, kwargs...
)
    isnothing(resp) && begin
        @warn "trying to create limit order with empty response ($(raw(ai)))"
        return nothing
    end
    try
        pyisTrue(get_py(resp, "status") == @pystr("open")) ||
            get_float(resp, "filled") > ZERO ||
            begin
                @warn "Order is not open, and does not appear to be fillled"
                return nothing
            end
    catch
    end
    type = let ot = _ordertif(resp)
        if isnothing(ot)
            t
        else
            side = @something _orderside(resp) orderside(t)
        end
    end
    amount = @something _orderfloat(resp, @pystr("amount")) amount
    price = @something _orderfloat(resp, @pystr("price")) price
    stop = _orderfloat(resp, @pystr("stopLossPrice"))
    take = _orderfloat(resp, @pystr("takeProfitPrice"))
    date = @something pytodate(resp) now()
    id = @something _orderid(resp) begin
        @warn "Missing order id for ($(nameof(s))@$(raw(ai))), defaulting to price-time hash"
        string(hash((price, date)))
    end
    o = create_sim_limit_order(
        s, type, ai; id, amount, date, type, price, stop, take, kwargs...
    )
    isnothing(o) || set_active_order!(s, ai, o)
    return o
end

function create_live_limit_order(
    s::LiveStrategy, ai::AssetInstance, args...; t, amount, price=lastprice(ai), kwargs...
)
    resp = live_send_order(s, ai, t, args...; amount, price, kwargs...)
    create_live_limit_order(s, resp, ai; amount, price, t, kwargs...)
end

macro _isfilled()
    expr = quote
        # fallback to local
        if isfilled(o)
            decommit!(s, o, ai)
            delete!(s, ai, o)
        end
    end
    esc(expr)
end

islist(v) = pyisinstance(v, pybuiltins.list)
isdict(v) = pyisinstance(v, pybuiltins.dict)
function isfilled(resp::Py)
    pyisTrue(get_py(resp, "filled") == get_py(resp, "amount")) &&
        iszero(get_float(resp, "remaining"))
end
@doc "Remove a limit order from orders queue if it is filled."
function aftertrade!(s::LiveStrategy, ai, o::AnyLimitOrder)
    resp = fetch_orders(s, ai; ids=(o.id,))
    if islist(resp) && !isempty(resp)
        o = first(resp)
        if isdict(o)
            if isfilled(o)
                decommit!(s, o, ai)
                delete!(s, ai, o)
            end
        else
            @_isfilled()
        end
    else
        @_isfilled()
    end
end
