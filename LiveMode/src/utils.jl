using PaperMode.OrderTypes
using PaperMode: reset_logs, SimMode
using .SimMode: _simmode_defaults!
using .Lang: @lget!
using .Python: @pystr, Py, PyList, @py, pylist
import .Executors.Instances: raw
using .TimeTicks: dtstamp

raw(v::AbstractString) = v
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
    resp isa PyException && throw(resp)
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

function _open_orders_func!(attrs, exc; open=true)
    # TODO: `watchOrders` support
    oc = open ? "open" : "closed"
    cap = open ? "Open" : "Closed"
    attrs[Symbol("live_$(oc)_orders_func")] = if has(exc, Symbol("fetch$(cap)Orders"))
        (ai; kwargs...) ->
            _fetch_orders(ai, getproperty(exc, Symbol("fetch$(cap)Orders")); kwargs...)
    else
        fetch_func = get(attrs, :live_orders_func, nothing)
        @assert !isnothing(fetch_func) "`live_orders_func` must be set before `live_$(oc)_orders_func`"
        open_str = @pystr("open")
        pred_func = o -> pyisTrue(o.get("status") == open_str)
        pred_func = open ? pred_func : !pred_func
        (ai; kwargs...) -> let out = pylist()
            all_orders = fetch_func(raw(ai); kwargs...)
            for o in all_orders
                pred_func(o) && out.append(o)
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
    attrs[:live_cancel_all_func] = if has(exc, :cancelAllOrders)
        func = first(exc, :cancelAllOrdersWs, :cancelAllOrders)
        (ai) -> _execfunc(func, raw(ai))
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

function _create_order_func!(attrs, exc)
    func = first(exc, :createOrderWs, :createOrder)
    @assert !isnothing(func) "Exchange doesn't have a `create_order` function"
    attrs[:live_create_order_func] =
        (args...; kwargs...) -> _execfunc(func, args...; kwargs...)
end

function _ordertrades(resp, isid=(x) -> length(x) > 0)
    (pyisnone(resp) || resp isa PyException || isempty(resp)) && return nothing
    out = pylist()
    for o in resp
        id = o.get("order")
        (pyisinstance(id, pybuiltins.str) && isid(id)) && out.append(o)
    end
    out
end

_skipkwargs(; kwargs...) = ((k => v for (k, v) in pairs(kwargs) if !isnothing(v))...,)

function _my_trades_func!(attrs, exc)
    # TODO: watchMyTrades support
    attrs[:live_my_trades_func] = if has(exc, :fetchMyTrades)
        let f = exc.fetchMyTrades
            (
                (ai; since=nothing, params=nothing) ->
                    _execfunc(f, raw(ai); _skipkwargs(; since, params)...)
            )
        end
        # TODO: watcTrades support
    elseif has(exc, :fetchTrades)
        let f = first(exc, :fetchTradesWs, :fetchTrades)
            (
                (ai; since=nothing, params=nothing) ->
                    let resp = _execfunc(f, raw(ai); _skipkwargs(; since, params)...)
                        _ordertrades(resp)
                    end
            )
        end
    else
        error("Exchange $(nameof(exc)) does not have a method to fetch account trades")
    end
end

_isstrequal(a::Py, b::String) = string(a) == b
_isstrequal(a::Py, b::Py) = pyisTrue(a == b)
_ispydict(v) = pyisinstance(v, pybuiltins.dict)

function _order_trades_func!(attrs, exc)
    attrs[:live_order_trades_func] = if has(exc, :fetchOrderTrades)
        f = exc.fetchOrderTrades
        (ai, id; since=nothing, params=nothing) ->
            _execfunc(f; symbol=raw(ai), id, _skipkwargs(; since, params)...)
    else
        fetch_func = attrs[:live_my_trades_func]
        o_func = attrs[:live_orders_func]
        o_closed_func = attrs[:live_closed_orders_func]
        (ai, id; since=nothing, params=nothing) -> begin
            since =
                ((@something since let ords = _execfunc(o_func, ai; ids=(id,))
                        try
                            if isempty(ords) # its possible for the order to not be present in
                                # the fetch orders function if it is closed
                                ords = _execfunc(o_closed_func, ai; ids=(id,))
                            end
                            pytodate(ords[0])
                        catch
                            now()
                        end
                    end) |> dtstamp) - 1
            let resp = _execfunc(fetch_func, ai; _skipkwargs(; since, params)...)
                _ordertrades(resp, ((x) -> string(x) == id))
            end
        end
    end
end

function _fetch_candles_func!(attrs, exc)
    fetch_func = first(exc, :fetcOHLCVWs, :fetchOHLCV)
    attrs[:live_fetch_candles_func] = (args...; kwargs...) -> _execfunc(fetch_func, args...; kwargs...)
end

function exc_live_funcs!(s::Strategy{Live})
    attrs = s.attrs
    exc = exchange(s)
    _orders_func!(attrs, exc)
    _create_order_func!(attrs, exc)
    _positions_func!(attrs, exc)
    _cancel_orders_func!(attrs, exc)
    _cancel_all_orders_func!(attrs, exc)
    _open_orders_func!(attrs, exc; open=true)
    _open_orders_func!(attrs, exc; open=false)
    _my_trades_func!(attrs, exc)
    _order_trades_func!(attrs, exc)
    _fetch_candles_func!(attrs, exc)
end

fetch_orders(s, args...; kwargs...) = st.attr(s, :live_orders_func)(args...; kwargs...)
function fetch_open_orders(s, args...; kwargs...)
    st.attr(s, :live_open_orders_func)(args...; kwargs...)
end
function fetch_closed_orders(s, args...; kwargs...)
    st.attr(s, :live_closed_orders_func)(args...; kwargs...)
end
function fetch_positions(s, ai::AssetInstance, args...; kwargs...)
    fetch_positions(s, (ai,), args...; kwargs...)
end
function fetch_positions(s, args...; kwargs...)
    st.attr(s, :live_positions_func)(args...; kwargs...)
end
cancel_orders(s, args...; kwargs...) = st.attr(s, :live_cancel_func)(args...; kwargs...)
function cancel_all_orders(s, args...; kwargs...)
    st.attr(s, :live_cancel_all_func)(args...; kwargs...)
end
function create_order(s, args...; kwargs...)
    st.attr(s, :live_create_order_func)(args...; kwargs...)
end
function fetch_my_trades(s, args...; kwargs...)
    st.attr(s, :live_my_trades_func)(args...; kwargs...)
end
function fetch_order_trades(s, args...; kwargs...)
    st.attr(s, :live_order_trades_func)(args...; kwargs...)
end
function fetch_candles(s, args...; kwargs...)
    st.attr(s, :live_fetch_candles_func)(args...; kwargs...)
end

function st.current_total(s::NoMarginStrategy{Live})
    bal = balance(s)
    price_func(ai) = bal[@pystr(raw(ai))] |> pytofloat
    invoke(st.current_total, Tuple{NoMarginStrategy,Function}, s, price_func)
end
