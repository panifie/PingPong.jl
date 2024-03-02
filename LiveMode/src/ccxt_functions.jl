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
    # first fetch the orders list
    all_orders = let
        kwargs = if isnothing(side)
            (;)
        else
            (; side)
        end
        if isempty(ids) && !(ids isa Tuple)
            ids = ()
        end
        _execfunc(orders_f, ai; kwargs..., ids)
    end
    if isemptish(all_orders)
        # no orders to cancel
        return
    end
    # cancel orders based on their status and side
    open_orders = (
        (
            o for o in all_orders if pyeq(Bool, resp_order_status(o, eid), @pyconst("open"))
        )...,
    )
    if !isemptish(open_orders)
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
function _fetch_orders(ai, this_func; eid, side=Both, ids=(), kwargs...)
    symbol = isnothing(ai) ? nothing : raw(ai)
    resp = _execfunc(this_func; symbol, kwargs...)
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
        elseif resp_all isa Exception && occursin("symbol", string(resp_all))
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
        function ccxt_orders_multi(ai; kwargs...)
            _tryfetchall(a, func, ai; kwargs...)
        end
    elseif !isnothing(fetch_single_func)
        function ccxt_orders_single(ai; ids, side=Both, kwargs...)
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
    @assert !isnothing(func) "$(nameof(exc)) doesn't have a `create_order` function"
    a[:live_send_order_func] = ccxt_create_order(args...; kwargs...) = _execfunc(func, args...; kwargs...)
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
    get!(a, :positions_ttl, Second(3))
    l, cache = _positions_resp_cache(a)
    a[:live_positions_func] = if has(exc, :fetchPositions)
        function ccxt_positions_multi(ais; side=Hedged(), timeout=base_timeout[], kwargs...)
            syms = ((raw(ai) for ai in ais)..., side)
            out = @get cache syms @lock l @lget! cache syms if isempty(ais)
                pylist()
            else
                timeout += base_timeout[]
                sleep(pre_timeout[])
                out = positions_func(exc, ais; timeout, kwargs...)
                out = handle_list_resp(eid, out, timeout, pre_timeout, base_timeout)
                default_side_func(resp) = _last_posside(_matching_asset(resp, eid, ais))
                _filter_positions(out, eid, side; default_side_func)
            end
        end
    else
        function ccxt_positions_single(ais; side=Hedged(), timeout=base_timeout[], kwargs...)
            syms = ((raw(ai) for ai in ais)..., side)
            @get cache syms @lock l @lget! cache syms @sync begin
                out = pylist()
                timeout += base_timeout[]
                for ai in ais
                    @async begin
                        sleep(pre_timeout[])
                        p = position_func(exc, ai; timeout, kwargs...)
                        p = handle_list_resp(eid, p, timeout, pre_timeout, base_timeout)
                        last_side = _last_posside(ai)
                        default_side_func(_) = last_side
                        p_side = posside_fromccxt(p, eid; default_side_func)
                        if isside(p_side, side)
                            out.append(p)
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
    cancel_multi_f = first(exc, :cancelOrdersWs, :cancelOrders)
    a[:live_cancel_func] = if !isnothing(cancel_multi_f)
        ccxt_cancel_multi(ai; side=nothing, ids=()) = _cancel_orders(ai, side, ids, orders_f, cancel_multi_f)
    else
        cancel_single_f = first(exc, :cancelOrderWs, :cancelOrder)
        if !isnothing(cancel_single_f)
            cancel_loop_f(ids; symbol) = @sync for id in ids
                @async _execfunc(cancel_single_f, id; symbol)
            end
            ccxt_cancel_single(ai; side=nothing, ids=()) = _cancel_orders(ai, side, ids, orders_f, cancel_loop_f)
        else
            error("$(nameof(exc)) doesn't support any cancel order function.")
        end
    end
end

@doc "Sets up the [`cancel_all_orders`](@ref) closure for the ccxt exchange instance."
function ccxt_cancel_all_orders_func!(a, exc)
    cancel_all_f = first(exc, :cancelAllOrdersWs, :cancelAllOrders)
    a[:live_cancel_all_func] = if !isnothing(cancel_all_f)
        ccxt_cancel_all_multi(ai) = _execfunc(cancel_all_f, raw(ai))
    else
        orders_func = get(a, :live_orders_func, nothing)
        @assert !isnothing(orders_func) "$(nameof(exc)) doesn't support fetchOrders."
        cancel_func = get(a, :live_cancel_func, nothing)
        @assert !isnothing(orders_func) "$(nameof(exc)) doesn't support cancelAllOrders."
        ccxt_cancel_all_single(ai) = cancel_func(ai)
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

@doc """ Sets up the [`fetch_open_orders`](@ref) or [`fetch_closed_orders`](@ref) closure for the ccxt exchange instance.
"""
function ccxt_oc_orders_func!(a, exc; open=true)
    names = _func_syms(open)
    orders_func = first(exc, names.ws, names.fetch)
    eid = typeof(exchangeid(exc))
    a[names.key] = if !isnothing(orders_func)
        this_func(ai; kwargs...) = _fetch_orders(ai, orders_func; eid, kwargs...)
        if open
            ccxt_open_orders(args...; kwargs...) = this_func(args...; kwargs...)
        else
            ccxt_closed_orders(args...; kwargs...) = this_func(args...; kwargs...)
        end
    else
        orders_func = get(a, :live_orders_func, nothing)
        @assert !isnothing(orders_func) "`live_orders_func` must be set before `live_$(names.oc)_orders_func`"
        pred_func(o) = pyeq(Bool, resp_order_status(o, eid), @pyconst("open"))
        status_pred_func = open ? pred_func : !pred_func
        this_func_fallback(ai; kwargs...) = begin
            out = pylist()
            all_orders = orders_func(ai; kwargs...)
            for o in all_orders
                if status_pred_func(o)
                    out.append(o)
                end
            end
            out
        end
        if open
            ccxt_open_orders_fallback(args...; kwargs...) = this_func_fallback(args...; kwargs...)
        else
            ccxt_closed_orders_fallback(args...; kwargs...) = this_func_fallback(args...; kwargs...)
        end
    end
end

@doc "Sets up the [`fetch_my_trades`](@ref) closure for the ccxt exchange instance."
function ccxt_my_trades_func!(a, exc)
    mytrades_func = first(exc, :fetchMyTradesWs, :fetchMyTrades)
    a[:live_my_trades_func] = if !isnothing(mytrades_func)
        this_func = function (ai; since=nothing, params=nothing)
            _execfunc(mytrades_func, raw(ai); _skipkwargs(; since, params)...)
        end
        ccxt_my_trades(ai; since=nothing, params=nothing) = begin
            _tryfetchall(a, this_func, ai; since, params)
        end
    else
        @warn "$(nameof(exc)) does not have a method to fetch account trades (trades will be emulated)"
    end
end

_find_since(a, ai, id; orders_func, orderbyid_func, closedords_func) = begin
    try
        eid = exchangeid(ai)
        ords = @lget! _order_byid_resp_cache(a, ai) id (_execfunc(orderbyid_func, id, raw(ai)) |> resp_to_vec)
        if isemptish(ords)
            ords = @lget! _orders_resp_cache(a, ai) id (_execfunc(orders_func, ai; ids=(id,)) |> resp_to_vec)
            if isemptish(ords) # its possible for the order to not be present in
                # the fetch orders function if it is closed
                ords = @lget! _closed_orders_resp_cache(a, ai) id (_execfunc(closedords_func, ai; ids=(id,)) |> resp_to_vec)
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

resp_to_vec(resp) =
    if isnothing(resp) || ismissing(resp)
        []
    elseif resp isa Exception
        @debug "ccxt func error" exception = resp @caller
        []
    else
        [resp...]
    end

find_trades_since(a, ai, oid, funcs; exc, since, params) = begin
    trades_resp = pylist()
    trades_cache = _trades_resp_cache(a, ai)
    since = @something(since,
        _find_since(a, ai, oid; funcs.orders_func, funcs.orderbyid_func, funcs.closedords_func)
    )
    since -= Second(1)
    since_bound = since - round(a[:max_order_lookback], Millisecond)
    while since > since_bound
        resp = @lget! trades_cache since begin
            this_resp = _execfunc(funcs.mytrades_func; _skipkwargs(; since=dtstamp(since), params)...)
            this_trades = _ordertrades(this_resp, exc, ((x) -> string(x) == oid))
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

@doc """Sets up the [`fetch_order_trades`](@ref) closure for the ccxt exchange instance.

!!! warning "Uses caching"
"""
function ccxt_order_trades_func!(a, exc)
    a[:live_order_trades_func] = if has(exc, :fetchOrderTrades)
        f = first(exc, :fetchOrderTradesWs, :fetchOrderTrades)
        ccxt_order_trades(ai, id; since=nothing, params=nothing) = begin
            cache = _order_trades_resp_cache(a, ai)
            @lget! cache id resp_to_vec(_execfunc(f; symbol=raw(ai), id, _skipkwargs(; since, params)...))
        end
    else
        mytrades_func = a[:live_my_trades_func]
        orderbyid_func = @something first(exc, :fetchOrderWs, :fetchOrder) Returns(())
        orders_func = a[:live_orders_func]
        closedords_func = a[:live_closed_orders_func]
        funcs = (; orderbyid_func, orders_func, closedords_func, mytrades_func)
        ccxt_order_trades_fallback(ai, id; since=nothing, params=nothing) = begin
            # Filter recent trades history for trades matching the order
            trades_cache = _trades_resp_cache(a, ai)
            resp_latest = @lget! trades_cache LATEST_RESP_KEY resp_to_vec(
                _execfunc(mytrades_func; _skipkwargs(; params)...)
            )
            trades_resp = if isempty(resp_latest)
                []
            else
                this_trades = _ordertrades(resp_latest, exc, ((x) -> string(x) == id))
                if isnothing(this_trades)
                    missing
                else
                    Any[this_trades...]
                end
            end
            if isemptish(trades_resp)
                # Fallback to fetching trades history using since
                find_trades_since(a, ai, id, funcs; exc, since, params)
            else
                return trades_resp
            end
        end
    end
end

@doc "Sets up the [`fetch_candles`](@ref) closure for the ccxt exchange instance."
function ccxt_fetch_candles_func!(a, exc)
    ohlcv_func = first(exc, :fetcOHLCVWs, :fetchOHLCV)
    a[:live_fetch_candles_func] = if !isnothing(ohlcv_func)
        ccxt_fetch_candles(args...; kwargs...) = _execfunc(ohlcv_func, args...; kwargs...)
    else
        @warn "$(nameof(exc)) does not support fetchOHLCV"
    end
end

@doc "Sets up the [`fetch_l2ob`](@ref) closure for the ccxt exchange instance."
function ccxt_fetch_l2ob_func!(a, exc)
    ob_func = first(exc, :fetchOrderBookWs, :fetchOrderBook)
    a[:live_fetch_l2ob_func] = if !isnothing(ob_func)
        ccxt_fetch_l2ob(ai; kwargs...) = _execfunc(ob_func, raw(ai); kwargs...)
    else
        @warn "$(nameof(exc)) does not support fetchOrderBook"
    end
end
