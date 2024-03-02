using LRUCache: LRUCache
using .Misc.TimeToLive: safettl
using .Exchanges.Ccxt: py_except_name

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
    filterfrom!(all_orders) do o
        status = resp_order_status(o, eid)
        pyne(Bool, status, @pyconst("open"))
    end
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

_syms(ais) = pylist(raw(ai) for ai in ais)
@doc """ Filters positions based on exchange ID type and side.

$(TYPEDSIGNATURES)

This function filters positions from `out` based on the provided exchange ID type `eid` and the `side` (default is `Hedged`). It returns the filtered positions.

"""
function _filter_positions(out, eid::EIDType, side=Hedged(); default_side_func=Returns(nothing))
    if out isa Exception || (@something side Hedged()) isa Hedged
        out
    elseif isshort(side) || islong(side)
        filterfrom!(out) do p
            this_side = posside_fromccxt(p, eid; default_side_func)
            !isside(this_side, side)
        end
    end
end

@doc """ Fetches orders for a given asset instance.

$(TYPEDSIGNATURES)

This function fetches orders for a given asset instance `ai` using the provided `mytrades_func`. The `side` parameter (default is `Both`) and `ids` parameter (default is an empty tuple) allow filtering of the fetched orders. Additional keyword arguments `kwargs...` are passed to the fetch function.

"""
function _fetch_orders(ai, mytrades_func; eid, side=Both, ids=(), kwargs...)
    symbol = isnothing(ai) ? nothing : raw(ai)
    resp = _execfunc(mytrades_func; symbol, kwargs...)
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
    filterfrom!(should_skip, resp)
end

@doc """ Try to fetch all items to save api credits by passing `nothing` as asset instance, if supported
by the function being called, otherwise make the call with the asset instance as argument.

"""
function _tryfetchall(a, func, ai, args...; kwargs...)
    disable_all = @lget! a :live_disable_all Dict{Function,Bool}()
    # if the disable_all flag is set skip this call
    if !get!(disable_all, func, false)
        resp_all = func(nothing, args...; kwargs...)
        if islist(resp_all)
            if ai isa AssetInstance
                this_sym = @pystr(raw(ai))
                eid = exchangeid(ai)
                filterfrom!(resp_all) do o
                    pyne(Bool, resp_order_symbol(o, eid), this_sym)
                end
            end
            return resp_all
        elseif resp_all isa Exception && occursin("symbol argument", string(resp_all))
            disable_all[func] = true
        end
    end
    func(ai, args...; kwargs...)
end

## FUNCTIONS

@doc "Sets up the [`fetch_orders`](@ref) closure for the ccxt exchange instance."
function ccxt_orders_func!(a, exc)
    # NOTE: these function are not similar since the single fetchOrder functions
    # fetch by id, while fetchOrders might not find the order (if it is too old)
    open_orders_func = first(exc, :fetchOpenOrdersWs, :fetchOpenOrders)
    closed_orders_func = first(exc, :fetchClosedOrdersWs, :fetchClosedOrders)
    has_fallback = !(isnothing(open_orders_func) || isnothing(closed_orders_func))
    fetch_multi_func = first(exc, :fetchOrdersWs, :fetchOrders)
    fetch_single_func = first(exc, :fetchOrderWs, :fetchOrder)
    eid = typeof(exchangeid(exc))
    a[:live_orders_func] = if !isnothing(fetch_multi_func)
        func = function (ai; kwargs...)
            resp = _fetch_orders(ai, fetch_multi_func; eid, kwargs...)
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
        function fetch_orders_multi(ai; kwargs...)
            _tryfetchall(a, func, ai; kwargs...)
        end
    elseif !isnothing(fetch_single_func)
        function fetch_orders_single(ai; ids, side=Both, kwargs...)
            out = pylist()
            sym = raw(ai)
            @sync for id in ids
                @async let resp = _execfunc(fetch_single_func, id, sym; kwargs...)
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

function position_func(exc::Exchange, ai, args...; timeout, kwargs...)
    _execfunc_timeout(
        first(exc, :fetchPositionWs, :fetchPosition), raw(ai), args...; timeout, kwargs...
    )
end

function watch_positions_func(exc::Exchange, ais, args...; timeout, kwargs...)
    _execfunc_timeout(
        exc.watchPositions, _syms(ais), args...; timeout, kwargs...
    )
end

function watch_balance_func(exc::Exchange, args...; timeout, kwargs...)
    _execfunc_timeout(
        exc.watchBalance, args...; timeout, kwargs...
    )
end

function fetch_balance_func(exc::Exchange, args...; timeout, kwargs...)
    _execfunc_timeout(
        first(exc, :fetchBalanceWs, :fetchBalance), args...; timeout, kwargs...
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

function handle_list_resp(eid::EIDType, resp, timeout, pre_timeout, base_timeout)
    if ismissing(resp)
        @warn "ccxt: request timed out" resp eid base_timeout[]
        base_timeout[] += if timeout > Second(0)
            round(timeout, Second, RoundUp)
        else
            Second(1)
        end
        pylist()
    elseif resp isa Exception
        @warn "ccxt: request error" resp eid
        pre_timeout[] += Second(1)
        pylist()
    else
        resp
    end
end

@doc "Sets up the [`fetch_positions`](@ref) for the ccxt exchange instance."
function ccxt_positions_func!(a, exc)
    eid = typeof(exc.id)
    a[:positions_pre_timeout] = pre_timeout = Ref(Second(0))
    a[:positions_base_timeout] = base_timeout = Ref(Second(0))
    l, cache = _positions_resp_cache(a)
    a[:live_positions_func] = if has(exc, :fetchPositions)
        (ais; side=Hedged(), timeout=base_timeout[], kwargs...) -> begin
            syms = ((raw(ai) for ai in ais)..., side)
            out = @get cache syms @lock l @lget! cache syms if isempty(ais)
                pylist()
            else
                timeout += base_timeout[]
                sleep(pre_timeout[])
                out = positions_func(exc, ais; timeout, kwargs...)
                out = handle_list_resp(eid, out, timeout, pre_timeout, base_timeout)
                _filter_positions(out, eid, side, default_side_func=(resp) -> _last_posside(_matching_asset(resp, eid, ais)))
            end
        end
    else
        (ais; side=Hedged(), timeout=base_timeout[], kwargs...) -> begin
            syms = ((raw(ai) for ai in ais)..., side)
            @get cache syms @lock l @lget! cache syms @sync begin
                out = pylist()
                timeout += base_timeout[]
                for ai in ais
                    @async begin
                        sleep(pre_timeout[])
                        p = position_func(exc, ai; timeout, kwargs...)
                        if ismissing(p)
                            @warn "ccxt: fetch positions timedout" out eid side base_timeout[] maxlog = 1
                            @info round(timeout, Second, RoundUp)
                            base_timeout[] += if timeout > Second(0)
                                round(timeout, Second, RoundUp)
                            else
                                Second(1)
                            end
                        elseif p isa Exception
                            @warn "ccxt: fetch positions error" out eid side
                            pre_timeout[] += Second(1)
                        else
                            last_side = _last_posside(ai)
                            p_side = posside_fromccxt(p, eid; default_side_func=(p) -> last_side)
                            if isside(p_side, side)
                                out.append(p)
                            end
                        end
                    end
                end
                out
            end
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
        let orders_func = get(a, :live_orders_func, nothing)
            @assert !isnothing(orders_func) "Exchange $(nameof(exc)) doesn't support fetchOrders."
            if has(exc, :cancelOrders)
                cancel_func = first(exc, :cancelOrdersWs, :cancelOrders)
                (ai) -> _cancel_all_orders(ai, orders_func, cancel_func)
            elseif has(exc, :cancelOrder)
                cancel_func = first(exc, :cancelOrderWs, :cancelOrder)
                (ai) -> _cancel_all_orders_single(ai, orders_func, cancel_func)
            else
                error("Exchange $(nameof(exc)) doesn't have a method to cancel orders.")
            end
        end
    end
end

_func_syms(open) = begin
    oc = open ? :open : :closed
    cap = open ? :Open : :Closed
    fetch = Symbol(:fetch, cap, :Orders)
    ws = Symbol(:fetch, cap, :OrdersWs)
    key = Symbol(:live_, oc, :_orders_func)
    (; oc, fetch, ws, key)
end

@doc "Sets up the [`fetch_open_orders`](@ref) or [`fetch_closed_orders`](@ref) closure for the ccxt exchange instance."
function ccxt_open_orders_func!(a, exc; open=true)
    names = _func_syms(open)
    orders_func = first(exc, names.ws, names.fetch)
    eid = typeof(exchangeid(exc))
    a[names.key] = if !isnothing(orders_func)
        (ai; kwargs...) -> _fetch_orders(ai, orders_func; eid, kwargs...)
    else
        orders_func = get(a, :live_orders_func, nothing)
        @assert !isnothing(orders_func) "`live_orders_func` must be set before `live_$(names.oc)_orders_func`"
        pred_func = o -> pyeq(Bool, resp_order_status(o, eid), @pyconst("open"))
        status_pred_func = open ? pred_func : !pred_func
        (ai; kwargs...) -> let out = pylist()
            all_orders = orders_func(ai; kwargs...)
            for o in all_orders
                if status_pred_func(o)
                    out.append(o)
                end
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
_find_since(a, ai, id; orders_func, orderbyid_func, closedords_func) = begin
    try
        eid = exchangeid(ai)
        ords = @lget! _order_byid_resp_cache(a, ai) id (_execfunc(orderbyid_func, id, raw(ai)) |> _wrap_excp)
        if isemptish(ords)
            ords = @lget! _orders_resp_cache(a, ai) id (_execfunc(orders_func, ai; ids=(id,)) |> _wrap_excp)
            if isemptish(ords) # its possible for the order to not be present in
                # the fetch orders function if it is closed
                ords = @lget! _closed_orders_resp_cache(a, ai) id (_execfunc(closedords_func, ai; ids=(id,)) |> _wrap_excp)
            end
        end
        if isemptish(ords)
            @debug "live order trades: couldn't fetch trades (default to last day trades)" _module = LogCcxtFuncs order = id ai = raw(ai) exc = nameof(exchange(ai)) since = _last_trade_date(ai)
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
        @debug_backtrace LogCcxtFuncs
        _last_trade_date(ai)
    end
end

_resp_to_vec(resp) =
    if isnothing(resp) || ismissing(resp)
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
        mytrades_func = a[:live_my_trades_func]
        orderbyid_func = @something first(exc, :fetchOrderWs, :fetchOrder) Returns(())
        orders_func = a[:live_orders_func]
        closedords_func = a[:live_closed_orders_func]
        (ai, id; since=nothing, params=nothing) -> begin
            # Filter recent trades history for trades matching the order
            trades_cache = _trades_resp_cache(a, ai)
            trades_resp = let
                resp_latest = @lget! trades_cache LATEST_RESP_KEY _resp_to_vec(
                    _execfunc(mytrades_func; _skipkwargs(; params)...)
                )
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
                        orders_func, orderbyid_func, closedords_func)) - Second(1)
                since_bound = since - round(a[:max_order_lookback], Millisecond)
                while since > since_bound
                    resp = @lget! trades_cache since let
                        this_resp = _execfunc(mytrades_func; _skipkwargs(; since=dtstamp(since), params)...)
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
    ohlcv_func = first(exc, :fetcOHLCVWs, :fetchOHLCV)
    a[:live_fetch_candles_func] =
        (args...; kwargs...) -> _execfunc(ohlcv_func, args...; kwargs...)
end

@doc "Sets up the [`fetch_l2ob`](@ref) closure for the ccxt exchange instance."
function ccxt_fetch_l2ob_func!(a, exc)
    ob_func = first(exc, :fetchOrderBookWs, :fetchOrderBook)
    a[:live_fetch_l2ob_func] = (ai; kwargs...) -> _execfunc(ob_func, raw(ai); kwargs...)
end
