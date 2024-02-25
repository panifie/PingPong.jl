using LRUCache: LRUCache
using .Misc.TimeToLive: safettl

_skipkwargs(; kwargs...) = ((k => v for (k, v) in pairs(kwargs) if !isnothing(v))...,)

_isstrequal(a::Py, b::String) = string(a) == b
_isstrequal(a::Py, b::Py) = pyeq(Bool, a, b)
_ispydict(v) = pyisinstance(v, pybuiltins.dict)
@doc "Anything that can't be tested for emptiness is emptish."
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

@doc "Filter out items from a python list."
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

@doc """ Retrieves the trades for an order from a Python response.

$(TYPEDSIGNATURES)

This function retrieves the trades associated with an order from a Python response `resp` from a given exchange `exc`. The function uses the provided function `isid` to determine which trades are associated with the order.
"""
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

@doc """ Cancels all orders for a given asset instance.

$(TYPEDSIGNATURES)

This function cancels all orders for a given asset instance `ai`. It retrieves the orders using the provided function `orders_f` and cancels them using the provided function `cancel_f`.

"""
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
@doc """ Same as [`_cancel_all_orders`](@ref) but does one call for each order.  """
function _cancel_all_orders_single(ai, orders_f, cancel_f)
    _cancel_all_orders(
        ai, orders_f, ((ids; symbol) -> begin
            @sync for id in ids
                @async _execfunc(cancel_f, id; symbol)
            end
        end)
    )
end

@doc """ Cancels specified orders for a given asset instance.

$(TYPEDSIGNATURES)

This function cancels orders with specified `ids` for a given asset instance `ai` and a specific side (`side`). It retrieves the orders using the provided function `orders_f` and cancels them using the provided function `cancel_f`.

"""
function _cancel_orders(ai, side, ids, orders_f, cancel_f)
    sym = raw(ai)
    eid = exchangeid(ai)
    all_orders = _execfunc(
        orders_f, ai; (isnothing(side) ? () : (; side))..., ids=(isempty(ids) ? () : ids)
    )
    if isemptish(all_orders)
        return
    end
    open_orders = (
        (
            o for o in all_orders if pyeq(Bool, resp_order_status(o, eid), @pyconst("open"))
        )...,
    )
    if !isempty(open_orders)
        if side === Buy || side === Sell
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
@doc """ Filters positions based on exchange ID type and side.

$(TYPEDSIGNATURES)

This function filters positions from `out` based on the provided exchange ID type `eid` and the `side` (default is `Hedged`). It returns the filtered positions.

"""
function _filter_positions(out, eid::EIDType, side=Hedged(); default_side_func=Returns(nothing))
    if out isa Exception || (@something side Hedged()) isa Hedged
        out
    elseif isshort(side) || islong(side)
        _pyfilter!(out, (p) -> !isside(posside_fromccxt(p, eid; default_side_func), side))
    end
end

@doc """ Fetches orders for a given asset instance.

$(TYPEDSIGNATURES)

This function fetches orders for a given asset instance `ai` using the provided `fetch_func`. The `side` parameter (default is `Both`) and `ids` parameter (default is an empty tuple) allow filtering of the fetched orders. Additional keyword arguments `kwargs...` are passed to the fetch function.

"""
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
        let ids_set = Set(eltype(ids) == String ? ids : (string(id) for id in ids))
            (o) -> (resp_order_id(o, eid, String) ∉ ids_set || notside(o))
        end
    end
    if resp isa PyException
        @error "ccxt fetch orders" raw(ai) resp
        return nothing
    end
    _pyfilter!(resp, should_skip)
end

## FUNCTIONS

@doc "Sets up the [`fetch_orders`](@ref) closure for the ccxt exchange instance."
function ccxt_orders_func!(a, exc)
    # NOTE: these function are not similar since the single fetchOrder functions
    # fetch by id, while fetchOrders might not find the order (if it is too old)
    has_fallback = has(exc, :fetchOpenOrders) && has(exc, :fetchClosedOrders)
    a[:live_orders_func] = if has(exc, :fetchOrders)
        f = first(exc, :fetchOrdersWs, :fetchOrders)
        (ai; kwargs...) -> let resp = _fetch_orders(ai, f; kwargs...)
            if isemptish(resp)
                out = pylist()
                if has_fallback
                    @sync begin
                        @async out.extend(a[:live_open_orders_func](ai; kwargs...))
                        @async out.extend(a[:live_closed_orders_func](ai; kwargs...))
                    end
                end
                out
            else
                resp
            end
        end
    elseif has(exc, :fetchOrder)
        f = first(exc, :fetchOrderWs, :fetchOrder)
        (ai; ids, side=Both, kwargs...) -> let out = pylist()
            sym = raw(ai)
            @sync for id in ids
                @async let resp = _execfunc(f, id, sym; kwargs...)
                    if !isemptish(resp)
                        out.append(resp)
                    end
                end
            end
            out
        end
    else
        @warn "ccxt funcs: fetch orders not supported" exchange = nameof(exc)
    end
end

@doc "Sets up the [`create_order`](@ref) closure for the ccxt exchange instance."
function ccxt_create_order_func!(a, exc)
    func = first(exc, :createOrderWs, :createOrder)
    @assert !isnothing(func) "Exchange doesn't have a `create_order` function"
    a[:live_send_order_func] = (args...; kwargs...) -> _execfunc(func, args...; kwargs...)
end

function positions_func(exc::Exchange, ais, args...; timeout, kwargs...)
    _execfunc_timeout(
        first(exc, :fetchPositionsWs, :fetchPositions), _syms(ais), args...; timeout, kwargs...
    )
end

function _matching_asset(resp, eid, ais)
    sym = resp_position_symbol(resp, eid, String)
    for ai in ais
        if sym == raw(ai)
            return ai
        end
    end
    return nothing
end

@doc "Sets up the [`fetch_positions`](@ref) for the ccxt exchange instance."
function ccxt_positions_func!(a, exc)
    eid = typeof(exc.id)
    timeout = get!(a, :throttle, Second(5))
    a[:live_positions_func] = if has(exc, :fetchPositions)
        (ais; side=Hedged(), kwargs...) -> if isempty(ais)
            pylist()
        else
            out = positions_func(exc, ais; timeout, kwargs...)
            if !ismissing(out)
                _filter_positions(out, eid, side, default_side_func=(resp) -> _last_posside(_matching_asset(resp, eid, ais)))
            else
                @warn "ccxt: fetch positions failed(missing)" get(ais, 1, missing) eid side timeout
                pylist()
            end
        end
    else
        fetch_func = exc.fetchPosition
        (ais; side=Hedged(), kwargs...) -> let out = pylist()
            @sync for ai in ais
                @async let p = _execfunc_timeout(fetch_func, raw(ai); timeout)
                    last_side = _last_posside(ai)
                    p_side = posside_fromccxt(p, eid; default_side_func=(p) -> last_side)
                    if isside(p_side, side)
                        out.append(p)
                    end
                end
            end
            out
        end
    end
end

@doc "Sets up the [`cancel_order`](@ref) closure for the ccxt exchange instance."
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

@doc "Sets up the [`cancel_all_orders`](@ref) closure for the ccxt exchange instance."
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

@doc "Sets up the [`fetch_open_orders`](@ref) or [`fetch_closed_orders`](@ref) closure for the ccxt exchange instance."
function ccxt_open_orders_func!(a, exc; open=true)
    oc = open ? "open" : "closed"
    cap = open ? "Open" : "Closed"
    func_sym = Symbol("fetch", cap, "Orders")
    func_sym_ws = Symbol("fetch", cap, "OrdersWs")
    a[Symbol("live_", oc, "_orders_func")] = if has(exc, func_sym)
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

@doc "Sets up the [`fetch_my_trades`](@ref) closure for the ccxt exchange instance."
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

_wrap_excp(v) =
    if v isa Exception
        []
    else
        [i for i in v]
    end
_find_since(a, ai, id; o_func, o_id_func, o_closed_func) = begin
    try
        eid = exchangeid(ai)
        ords = @lget! _order_byid_resp_cache(a, ai) id (_execfunc(o_id_func, id, raw(ai)) |> _wrap_excp)
        if isemptish(ords)
            ords = @lget! _orders_resp_cache(a, ai) id (_execfunc(o_func, ai; ids=(id,)) |> _wrap_excp)
            if isemptish(ords) # its possible for the order to not be present in
                # the fetch orders function if it is closed
                ords = @lget! _closed_orders_resp_cache(a, ai) id (_execfunc(o_closed_func, ai; ids=(id,)) |> _wrap_excp)
            end
        end
        if isemptish(ords)
            @debug "live order trades: couldn't fetch trades (default to last day trades)" order = id ai = raw(ai) exc = nameof(exchange(ai)) since = _last_trade_date(ai)
            _last_trade_date(ai)
        else
            o = if isdict(ords)
                ords
            elseif islist(ords) || ords isa Vector
                first(ords)
            else
                @error "live order trades: unexpected returned value" id ords
                error()
            end
            trades_resp = resp_order_trades(o, eid)
            if isemptish(trades_resp)
                @something resp_order_timestamp(o, eid) findorder(ai, id; property=:date) _last_trade_date(ai)
            else
                return trades_resp
            end
        end
    catch
        @debug_backtrace
        _last_trade_date(ai)
    end
end

_resp_to_vec(resp) =
    if isnothing(resp)
        []
    elseif resp isa Exception
        @debug "ccxt func error" exception = resp @caller
        []
    else
        [resp...]
    end

@doc """Sets up the [`fetch_order_trades`](@ref) closure for the ccxt exchange instance.

!!! warning "Uses caching"
"""
function ccxt_order_trades_func!(a, exc)
    a[:live_order_trades_func] = if has(exc, :fetchOrderTrades)
        f = first(exc, :fetchOrderTradesWs, :fetchOrderTrades)
        (ai, id; since=nothing, params=nothing) -> begin
            cache = _order_trades_resp_cache(a, ai)
            @lget! cache id _resp_to_vec(_execfunc(f; symbol=raw(ai), id, _skipkwargs(; since, params)...))
        end
    else
        fetch_func = a[:live_my_trades_func]
        o_id_func = @something first(exc, :fetchOrderWs, :fetchOrder) Returns(())
        o_func = a[:live_orders_func]
        o_closed_func = a[:live_closed_orders_func]
        (ai, id; since=nothing, params=nothing) -> begin
            # Filter recent trades history for trades matching the order
            trades_cache = _trades_resp_cache(a, ai)
            trades_resp = let resp_latest = @lget! trades_cache LATEST_RESP_KEY _resp_to_vec(_execfunc(fetch_func, ai; _skipkwargs(; params)...))
                if isempty(resp_latest)
                    []
                else
                    this_trades = _ordertrades(resp_latest, exc, ((x) -> string(x) == id))
                    if isnothing(this_trades)
                        missing
                    else
                        Any[this_trades...]
                    end
                end
            end
            !isemptish(trades_resp) && return trades_resp
            # Fallback to fetching trades history using since
            trades_resp = pylist()
            let since = @something(since,
                    _find_since(a, ai, id;
                        o_func, o_id_func, o_closed_func)) - Second(1)
                since_bound = since - round(a[:max_order_lookback], Millisecond)
                while since > since_bound
                    resp = @lget! trades_cache since let this_resp = _execfunc(fetch_func, ai; _skipkwargs(; since=dtstamp(since), params)...)
                        this_trades = _ordertrades(this_resp, exc, ((x) -> string(x) == id))
                        if isnothing(this_trades)
                            missing
                        else
                            [this_trades...]
                        end
                    end
                    if !isemptish(resp)
                        trades_resp.extend(resp)
                        break
                    end
                    since -= Day(1)
                end
                return trades_resp
            end
        end
    end
end

@doc "Sets up the [`fetch_candles`](@ref) closure for the ccxt exchange instance."
function ccxt_fetch_candles_func!(a, exc)
    fetch_func = first(exc, :fetcOHLCVWs, :fetchOHLCV)
    a[:live_fetch_candles_func] =
        (args...; kwargs...) -> _execfunc(fetch_func, args...; kwargs...)
end

@doc "Sets up the [`fetch_l2ob`](@ref) closure for the ccxt exchange instance."
function ccxt_fetch_l2ob_func!(a, exc)
    fetch_func = first(exc, :fetchOrderBookWs, :fetchOrderBook)
    a[:live_fetch_l2ob_func] = (ai; kwargs...) -> _execfunc(fetch_func, raw(ai); kwargs...)
end
