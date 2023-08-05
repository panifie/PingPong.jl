using PaperMode.OrderTypes
using PaperMode: reset_logs
using .Lang: @lget!
using .Python: @pystr, Py, PyList

function OrderTypes.ordersdefault!(s::Strategy{Live})
    let attrs = s.attrs
        _simmode_defaults!(s, attrs)
        reset_logs(s)
    end
end

_pyfilter!(out, pred::Function) = begin
    n = 0
    while n < length(out)
        o = out[n]
        if pred(o)
            out.pop(n)
        else
            n += 1
        end
    end
    out
end

function _fetch_orders(ai, fetch_func; side=Both, ids=(), kwargs...)
    symbol = raw(ai)
    resp = _execfunc(fetch_func; symbol, kwargs...)
    notside = let sides = if side == Both
            (_ccxtorderside(Buy), _ccxtorderside(Sell))
        else
            (_ccxtorderside(side),)
        end
        (o) -> @py o.get("side") ∉ sides
    end
    should_skip = if isempty(ids)
        if side == Both
            Returns(false)
        else
            notside
        end
    else
        let ids_set = Set(ids)
            (o) -> (pyconvert(String, o.get("id")) ∉ ids_set || notside(o))
        end
    end
    _pyfilter!(resp, should_skip)
end

function _orders_func!(attrs, exc)
    # TODO: `watchOrders` support
    attrs[:live_orders_func] = if has(exc, :fetchOrders)
        (ai; kwargs...) -> _fetch_orders(ai, exc.fetchOrders; kwargs...)
    elseif has(exc, :fetchOrder)
        (ai; ids, kwargs...) -> let out = pylist()
            @sync for id in ids
                @async out.append(_execfunc(exc.fetchOrder, ai, id; kwargs...))
            end
            out
        end
    end
end

_syms(ais) = ((raw(ai) for ai in ais)...,)
function _filter_positions(out, side::Union{Hedged,PositionSide}=Hedged())
    if (@something side Hedged()) == Hedged()
        out
    elseif isshort(side) || islong(side)
        side_str = @pystr(_ccxtposside(side))
        _pyfilter!(out, (o) -> pyisTrue(o.get("side") != side_str))
    end
end

function _positions_func!(attrs, exc)
    # TODO: `watchPositions` support
    attrs[:live_positions_func] = if has(exc, :fetchPositions)
        (ais; side=Hedged(), kwargs...) ->
            let out = pyfetch(exc.fetchPositions, _syms(ais); kwargs...)
                _filter_positions(out, side)
            end
    else
        (ais; side=Hedged(), kwargs...) -> let out = pylist()
            @sync for ai in ais
                @async out.append(pyfetch(exc.fetchPosition, raw(ai); kwargs...))
            end
            _filter_positions(out, side)
        end
    end
end

_execfunc(f::Py, args...; kwargs...) = @mock pyfetch(f, args...; kwargs...)
_execfunc(f::Function, args...; kwargs...) = @mock f(args...; kwargs...)

function _cancel_all_orders(ai, orders_f, cancel_f)
    let sym = raw(ai)
        all_orders = _execfunc(orders_f, ai)
        _pyfilter!(all_orders, o -> pyisTrue(o.get("status") != @pystr("open")))
        if !isempty(all_orders)
            ids = ((o.get("id") for o in all_orders)...,)
            _execfunc(cancel_f, ids; symbol=sym)
        end
    end
end
function _cancel_all_orders_single(ai, orders_f, cancel_f)
    _cancel_all_orders(
        ai, orders_f, ((ids; symbol) -> begin
            @sync for id in ids
                @async _execfunc(cancel_f, id; symbol)
            end
        end)
    )
end

function _cancel_all_orders_func!(attrs, exc)
    attrs[:live_cancel_all_func] = if has(exc, :cancelAllOrdersWs)
        (ai) -> _execfunc(exc.cancelAllOrdersWs, raw(ai))
    elseif has(exc, :cancelAllOrders)
        (ai) -> _execfunc(exc.cancelAllOrders, raw(ai))
    else
        let fetch_func = get(attrs, :live_orders_func, nothing)
            @assert !isnothing(fetch_func) "Exchange $(nameof(exc)) doesn't support fetchOrders."
            if has(exc, :cancelOrders)
                cancel_func = first(exc, :cancelOrdersWs, :cancelOrders)
                (ai) -> _cancel_all_orders(ai, fetch_func, cancel_func)
            elseif has(exc, :cancelOrder)
                cancel_func = first(exc, :cancelOrderWs, :cancelOrder)
                (ai) -> _cancel_all_orders_single(ai, fetch_func, cancel_func)
            else
                error("Exchange $(nameof(exc)) doesn't have a method to cancel orders.")
            end
        end
    end
end

function _cancel_orders(ai, side, ids, orders_f, cancel_f)
    sym = raw(ai)
    all_orders = _execfunc(orders_f, ai; (isnothing(side) ? () : (; side))...)
    open_orders = (
        (o for o in all_orders if pyisTrue(o.get("status") == @pystr("open")))...,
    )
    if !isempty(open_orders)
        if side ∈ (Buy, Sell)
            side_str = _ccxtorderside(side)
            side_ids = (
                (
                    o.get("id") for o in open_orders if pyisTrue(o.get("side") == side_str)
                )...,
            )
            _execfunc(cancel_f, side_ids; symbol=sym)
        else
            orders_ids = ((o.get("id") for o in open_orders)...,)
            _execfunc(cancel_f, orders_ids; symbol=sym)
        end
    end
end

function _cancel_orders_func!(attrs, exc)
    orders_f = attrs[:live_orders_func]
    attrs[:live_cancel_func] = if has(exc, :cancelOrders)
        cancel_f = first(exc, :cancelOrdersWs, :cancelOrders)
        (ai; side=nothing, ids=()) -> _cancel_orders(ai, side, ids, orders_f, cancel_f)
    elseif has(exc, :cancelOrder)
        cancel_f = let pyf = first(exc, :cancelOrderWs, :cancelOrder)
            (ids; symbol) -> @sync for id in ids
                @async _execfunc(pyf, id; symbol)
            end
        end
        (ai; side=nothing, ids=()) -> _cancel_orders(ai, side, ids, orders_f, cancel_f)
    else
        error("Exchange $(nameof(exc)) doesn't support any cancel order function.")
    end
end

function exc_live_funcs!(s::Strategy{Live})
    attrs = s.attrs
    exc = exchange(s)
    _orders_func!(attrs, exc)
    _positions_func!(attrs, exc)
    _cancel_orders_func!(attrs, exc)
    _cancel_all_orders_func!(attrs, exc)
end

fetch_orders(s, args...; kwargs...) = st.attr(s, :live_orders_func)(args...; kwargs...)
function fetch_positions(s, args...; kwargs...)
    st.attr(s, :live_positions_func)(args...; kwargs...)
end
cancel_orders(s, args...; kwargs...) = st.attr(s, :live_cancel_func)(args...; kwargs...)
function cancel_all_orders(s, args...; kwargs...)
    st.attr(s, :live_cancel_all_func)(args...; kwargs...)
end

function st.current_total(s::NoMarginStrategy{Live})
    bal = balance(s)
    price_func(ai) = bal[@pystr(raw(ai))] |> pytofloat
    invoke(st.current_total, Tuple{NoMarginStrategy,Function}, s, price_func)
end
