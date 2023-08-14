using .Executors: AnyLimitOrder
using .PaperMode: _asdate, create_sim_limit_order

_ordertif(o::Py) =
    let tif = o.get("timeInForce")
        if tif == "PO" || tif == "GTC"
            GTCOrder
        elseif tif == "FOK"
            FOKOrder
        elseif tif == "IOC"
            IOCOrder
        end
    end

_orderside(o::Py) =
    let v = o.get("side")
        if v == @pystr("buy")
            Buy
        elseif v == @pystr("sell")
            Sell
        end
    end

_orderfloat(o::Py, k) =
    let v = o.get(k)
        if pyisinstance(v, pybuiltins.float)
            pytofloat(v)
        end
    end

pytodate(py::Py) =
    let v = py.get("timestamp")
        if pyisinstance(v, pybuiltins.str)
            _asdate(v)
        elseif pyisinstance(v, pybuiltins.int)
            pyconvert(Int, v) |> dt
        elseif pyisinstance(v, pybuiltins.float)
            pyconvert(DFT, v) |> dt
        end
    end

_orderid(o::Py) =
    let v = o.get("id")
        if pyisinstance(v, pybuiltins.str)
            return string(v)
        else
            v = o.get("clientOrderId")
            if pyisinstance(v, pybuiltins.str)
                return string(v)
            end
        end
    end

function create_live_limit_order(
    s::LiveStrategy, resp, ai, args...; t, price, amount, kwargs...
)
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
    date = @something _pytodate(resp) now()
    id = @something _orderid(resp) begin
        @warn "Missing order id for ($(nameof(s))@$(raw(ai))), defaulting to price-time hash"
        string(hash((price, date)))
    end
    create_sim_limit_order(
        s, type, ai; id, amount, date, type, price, stop, take, kwargs...
    )
end
