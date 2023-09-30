_skipkwargs(; kwargs...) = ((k => v for (k, v) in pairs(kwargs) if !isnothing(v))...,)

_isstrequal(a::Py, b::String) = string(a) == b
_isstrequal(a::Py, b::Py) = pyeq(Bool, a, b)
_ispydict(v) = pyisinstance(v, pybuiltins.dict)
isemptish(v::Py) =
    try
        pyisnone(v) || isempty(v)
    catch
        true
    end
isemptish(v) =
    try
        isnothing(v) || isempty(v)
    catch
        true
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

function _ordertrades(resp, exc, isid=(x) -> length(x) > 0)
    (pyisnone(resp) || resp isa PyException || isempty(resp)) && return nothing
    out = pylist()
    eid = typeof(exc.id)
    append = out.append
    for o in resp
        id = resp_trade_order(o, eid)
        (pyisinstance(id, pybuiltins.str) && isid(id)) && append(o)
    end
    out
end

function _cancel_all_orders(ai, orders_f, cancel_f)
    sym = raw(ai)
    eid = exchangeid(ai)
    all_orders = _execfunc(orders_f, ai)
    _pyfilter!(all_orders, o -> pyne(Bool, resp_order_status(o, eid), @pyconst("open")))
    if !isempty(all_orders)
        ids = ((resp_order_id(o, eid) for o in all_orders)...,)
        _execfunc(cancel_f, ids; symbol=sym)
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

function _cancel_orders(ai, side, ids, orders_f, cancel_f)
    sym = raw(ai)
    eid = exchangeid(ai)
    all_orders = _execfunc(orders_f, ai; (isnothing(side) ? () : (; side))...)
    open_orders = (
        (
            o for o in all_orders if pyeq(Bool, resp_order_status(o, eid), @pyconst("open"))
        )...,
    )
    if !isempty(open_orders)
        if side ∈ (Buy, Sell)
            side_str = _ccxtorderside(side)
            side_ids = (
                (
                    resp_order_id(o, eid) for
                    o in open_orders if pyeq(Bool, resp_order_side(o, eid), side_str)
                )...,
            )
            _execfunc(cancel_f, side_ids; symbol=sym)
        else
            orders_ids = ((resp_order_id(o, eid) for o in open_orders)...,)
            _execfunc(cancel_f, orders_ids; symbol=sym)
        end
    end
end

_syms(ais) = ((raw(ai) for ai in ais)...,)
function _filter_positions(out, eid::EIDType, side=Hedged())
    if (@something side Hedged()) isa Hedged
        out
    elseif isshort(side) || islong(side)
        _pyfilter!(out, (p) -> !isside(posside_fromccxt(p, eid), side))
    end
end

function _fetch_orders(ai, fetch_func; side=Both, ids=(), kwargs...)
    symbol = raw(ai)
    eid = exchangeid(ai)
    resp = _execfunc(fetch_func; symbol, kwargs...)
    notside = let sides = if side === Both # NOTE: strict equality
            (_ccxtorderside(Buy), _ccxtorderside(Sell))
        else
            (_ccxtorderside(side),)
        end |> pytuple
        (o) -> let s = resp_order_side(o, eid)
            @py s ∉ sides
        end
    end
    should_skip = if isempty(ids)
        if side === Both
            Returns(false)
        else
            notside
        end
    else
        let ids_set = Set(ids)
            (o) -> (resp_order_id(o, eid, String) ∉ ids_set || notside(o))
        end
    end
    if resp isa PyException
        @error "Error when fetching orders for $(raw(ai)) $resp"
        return nothing
    end
    _pyfilter!(resp, should_skip)
end

## FUNCTIONS

function ccxt_orders_func!(a, exc)
    # NOTE: these function are not similar since the single fetchOrder functions
    # fetch by id, while fetchOrders might not find the order (if it is too old)
    a[:live_orders_func] = if has(exc, :fetchOrders)
        (ai; kwargs...) ->
            _fetch_orders(ai, first(exc, :fetchOrdersWs, :fetchOrders); kwargs...)
    elseif has(exc, :fetchOrder)
        (ai; ids, kwargs...) -> let out = pylist()
            sym = raw(ai)
            @sync for id in ids
                @async out.append(
                    _execfunc(first(exc, :fetchOrderWs, :fetchOrder), id, sym; kwargs...),
                )
            end
            out
        end
    else
        @warn "ccxt funcs: fetch orders not supported" exchange = nameof(exc)
    end
end

function ccxt_create_order_func!(a, exc)
    func = first(exc, :createOrderWs, :createOrder)
    @assert !isnothing(func) "Exchange doesn't have a `create_order` function"
    a[:live_send_order_func] = (args...; kwargs...) -> _execfunc(func, args...; kwargs...)
end

function positions_func(exc::Exchange, ais, args...; kwargs...)
    pyfetch(first(exc, :fetchPositionsWs, :fetchPositions), _syms(ais), args...; kwargs...)
end

function ccxt_positions_func!(a, exc)
    eid = typeof(exc.id)
    a[:live_positions_func] = if has(exc, :fetchPositions)
        (ais; side=Hedged(), kwargs...) -> let out = positions_func(exc, ais; kwargs...)
            _filter_positions(out, eid, side)
        end
    else
        f = exc.fetchPosition
        (ais; side=Hedged(), kwargs...) -> let out = pylist()
            @sync for ai in ais
                @async out.append(pyfetch(f, raw(ai); kwargs...))
            end
            _filter_positions(out, eid, side)
        end
    end
end

function ccxt_cancel_orders_func!(a, exc)
    orders_f = a[:live_orders_func]
    a[:live_cancel_func] = if has(exc, :cancelOrders)
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

function ccxt_cancel_all_orders_func!(a, exc)
    a[:live_cancel_all_func] = if has(exc, :cancelAllOrders)
        func = first(exc, :cancelAllOrdersWs, :cancelAllOrders)
        (ai) -> _execfunc(func, raw(ai))
    else
        let fetch_func = get(a, :live_orders_func, nothing)
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

function ccxt_open_orders_func!(a, exc; open=true)
    oc = open ? "open" : "closed"
    cap = open ? "Open" : "Closed"
    func_sym = Symbol("fetch$(cap)Orders")
    func_sym_ws = Symbol("fetch$(cap)OrdersWs")
    a[Symbol("live_$(oc)_orders_func")] = if has(exc, func_sym)
        let f = first(exc, func_sym_ws, func_sym)
            (ai; kwargs...) -> _fetch_orders(ai, f; kwargs...)
        end
    else
        fetch_func = get(a, :live_orders_func, nothing)
        @assert !isnothing(fetch_func) "`live_orders_func` must be set before `live_$(oc)_orders_func`"
        eid = typeof(exchangeid(exc))
        pred_func = o -> pyeq(Bool, resp_order_status(o, eid), @pyconst("open"))
        status_pred_func = open ? pred_func : !pred_func
        (ai; kwargs...) -> let out = pylist()
            all_orders = fetch_func(ai; kwargs...)
            for o in all_orders
                status_pred_func(o) && out.append(o)
            end
            out
        end
    end
end

function ccxt_my_trades_func!(a, exc)
    a[:live_my_trades_func] = if has(exc, :fetchMyTrades)
        let f = first(exc, :fetchMyTradesWs, :fetchMyTrades)
            (
                (ai; since=nothing, params=nothing) -> begin
                    _execfunc(f, raw(ai); _skipkwargs(; since, params)...)
                end
            )
        end
    else
        @warn "Exchange $(nameof(exc)) does not have a method to fetch account trades (trades will be emulated)"
    end
end

function ccxt_order_trades_func!(a, exc)
    a[:live_order_trades_func] = if has(exc, :fetchOrderTrades)
        f = first(exc, :fetchOrderTradesWs, :fetchOrderTrades)
        (ai, id; since=nothing, params=nothing) ->
            _execfunc(f; symbol=raw(ai), id, _skipkwargs(; since, params)...)
    else
        fetch_func = a[:live_my_trades_func]
        o_id_func = @something first(exc, :fetchOrderWs, :fetchOrder) Returns(())
        o_func = a[:live_orders_func]
        o_closed_func = a[:live_closed_orders_func]
        (ai, id; since=nothing, params=nothing) -> begin
            resp_latest = _execfunc(fetch_func, ai; _skipkwargs(; params)...)
            trades = _ordertrades(resp_latest, exc, ((x) -> string(x) == id))
            !isemptish(trades) && return trades
            trades = nothing
            let since = (
                    (@something since try
                        eid = exchangeid(ai)
                        ords = _execfunc(o_id_func, id, raw(ai))
                        if isemptish(ords)
                            ords = _execfunc(o_func, ai; ids=(id,))
                            if isempty(ords) # its possible for the order to not be present in
                                # the fetch orders function if it is closed
                                ords = _execfunc(o_closed_func, ai; ids=(id,))
                            end
                        end
                        if isemptish(ords)
                            @debug "Couldn't fetch order id $id ($(raw(ai))@$(nameof(exc))) (defaulting to last day orders)"
                            now() - Day(1)
                        else
                            o = if isdict(ords)
                                ords
                            elseif islist(ords)
                                ords[0]
                            else
                                @error "Unexpected returned value while fetching orders for $id \n $ords"
                                return nothing
                            end
                            trades = resp_order_trades(o, eid)
                            if isemptish(trades)
                                resp_order_timestamp(o, eid)
                            else
                                return trades
                            end
                        end
                    catch
                        @debug_backtrace
                        now() - Day(1)
                    end) - Second(1) |> dtstamp
                )
                tries = 0
                while tries < 3 && isemptish(trades)
                    resp = _execfunc(fetch_func, ai; _skipkwargs(; since, params)...)
                    trades = _ordertrades(resp, exc, ((x) -> string(x) == id))
                    since -= 86400000
                    tries += 1
                end
                return trades
            end
        end
    end
end

function ccxt_fetch_candles_func!(a, exc)
    fetch_func = first(exc, :fetcOHLCVWs, :fetchOHLCV)
    a[:live_fetch_candles_func] =
        (args...; kwargs...) -> _execfunc(fetch_func, args...; kwargs...)
end
