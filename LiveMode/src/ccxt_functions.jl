using LRUCache: LRUCache
using .Misc.TimeToLive: safettl
using .Exchanges.Ccxt: py_except_name
using .Exchanges.Python: stream_handler, start_handler!, stop_handler!

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
hasels(v::Py) = !pyisnone(v) && !isempty(v)
hasels(v) = !isnothing(v) && !isempty(v)

@doc """ Retrieves the trades for an order from a Python response.

$(TYPEDSIGNATURES)

This function retrieves the trades associated with an order from a Python response `resp` from a given exchange `exc`. The function uses the provided function `isid` to determine which trades are associated with the order.
"""
function _ordertrades(resp, exc, isid=(x) -> length(x) > 0)
    if islist(resp)
        out = pylist()
        eid = typeof(exc.id)
        append = out.append
        for o in resp
            id = resp_trade_order(o, eid)
            if (pyisinstance(id, pybuiltins.str) && isid(id))
                append(o)
            end
        end
        out
    elseif resp isa Exception
        @error "ccxt trades filtering error" exception = resp
    elseif isemptish(resp) # At the end since an exception is also _emptish_
    end
end

@doc """ Cancels all orders for a given asset instance.

$(TYPEDSIGNATURES)

This function cancels all orders for a given asset instance `ai`. It retrieves the orders using the provided function `orders_f` and cancels them using the provided function `cancel_f`.

"""
function _cancel_all_orders(ai, orders_f, cancel_f)
    sym = raw(ai)
    eid = exchangeid(ai)
    all_orders = _execfunc(orders_f, ai)
    removefrom!(all_orders) do o
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
        removefrom!(out) do p
            this_side = posside_fromccxt(p, eid; default_side_func)
            !isside(this_side, side)
        end
    end
end

@doc """ Fetches orders for a given asset instance.

$(TYPEDSIGNATURES)

This function fetches orders for a given asset instance `ai` using the provided `mytrades_func`. The `side` parameter (default is `BuyOrSell`) and `ids` parameter (default is an empty tuple) allow filtering of the fetched orders. Additional keyword arguments `kwargs...` are passed to the fetch function.

"""
function _fetch_orders(ai, this_func; eid, side=BuyOrSell, ids=(), pred_funcs=(), kwargs...)
    resp = _execfunc(this_func, ai)
    if resp isa Exception
        @error "ccxt fetch orders" raw(ai) resp @caller
        return nothing
    end
    notside = let sides = if side === BuyOrSell # NOTE: strict equality
            (_ccxtorderside(Buy), _ccxtorderside(Sell))
        else
            (_ccxtorderside(side),)
        end |> pytuple
        (o) -> (sd = resp_order_side(o, eid); @py sd ∉ sides)
    end
    should_skip = if isempty(ids)
        if side === BuyOrSell
            Returns(false)
        else
            notside
        end
    else
        id_strings = if eltype(ids) == String
            ids
        else
            (string(id) for id in ids)
        end
        ids_set = Set(id_strings)
        (o) -> resp_order_id(o, eid, String) ∉ ids_set || notside(o)
    end
    filter_func(o) = should_skip(o) || any(f(o) for f in pred_funcs)
    removefrom!(filter_func, resp)
end

@doc """ Try to fetch all items to save api credits by passing `nothing` as asset instance, if supported
by the function being called, otherwise make the call with the asset instance as argument.

"""
function _tryfetchall(a, func, ai, args...; kwargs...)
    disable_all = @lget! a :live_disable_all Dict{Symbol,Bool}()
    func_name = nameof(func)
    # if the disable_all flag is set skip this call
    if !get(disable_all, func_name, false)
        func_lock, func_cache = _func_cache(a, func_name)
        since = (@something get(kwargs, :since, DateTime(0)) DateTime(0)) |> dt
        resp_all = @lock func_lock @lget! func_cache since begin
            func(nothing, args...; kwargs...)
        end
        if islist(resp_all)
            ans = pylist(resp_all)
            if ai isa AssetInstance
                this_sym = @pystr(raw(ai))
                eid = exchangeid(ai)
                removefrom!(ans) do o
                    pyne(Bool, resp_order_symbol(o, eid), this_sym)
                end
            end
            return ans
        else
            if resp_all isa Exception && !occursin("symbol", string(resp_all))
                @warn "fetch all failed" exception = resp_all f = @caller 14
            end
            @debug "fetch all: disabling" func_name
            disable_all[func_name] = true
        end
    end
    func(ai, args...; kwargs...)
end

issupported(exc, syms::Vararg{Symbol}) = begin
    all(let
        this_syms = (Symbol(sym, :Ws), sym)
        !isnothing(first(exc, this_syms...))
    end
        for sym in syms)
end

## FUNCTIONS

@doc "Sets up the [`fetch_orders`](@ref) closure for the ccxt exchange instance."
function ccxt_orders_func!(a, exc)
    # NOTE: these function are not similar since the single fetchOrder functions
    # fetch by id, while fetchOrders might not find the order (if it is too old)
    has_fallback = issupported(exc, :fetchOpenOrders, :fetchClosedOrders)
    fetch_multi_func = first(exc, :fetchOrdersWs, :fetchOrders)
    fetch_single_func = first(exc, :fetchOrderWs, :fetchOrder)
    eid = typeof(exchangeid(exc))
    function orders_multi_fallback(ai; kwargs...)
        out = pylist()
        @sync begin
            @async begin
                v = a[:live_open_orders_func](ai; kwargs...)
                if islist(v)
                    out.extend(v)
                end
            end
            @async begin
                v = a[:live_closed_orders_func](ai; kwargs...)
                if islist(v)
                    out.extend(v)
                end
            end
        end
        out_unique = unique!([out...]) do o
            resp_order_id(o, exchangeid(ai))
        end |> pylist
        _fetch_orders(ai, Returns(out_unique); eid=exchangeid(ai), kwargs...)
    end
    a[:live_orders_func] = if !isnothing(fetch_multi_func)
        fetch_orders_multi(ai, args...; kwargs...) = begin
            sym = ai isa AssetInstance ? raw(ai) : nothing
            _execfunc(fetch_multi_func, sym, args...; kwargs...)
        end
        orders_multi_fetcher(ai, args...; kwargs...) = _tryfetchall(a, fetch_orders_multi, ai, args...; kwargs...)
        ccxt_orders_multi(ai; kwargs...) = begin
            resp = _fetch_orders(ai, orders_multi_fetcher; eid, kwargs...)
            if isemptish(resp) && has_fallback
                orders_multi_fallback(ai; kwargs...)
            else
                resp
            end
        end
    elseif has_fallback
        orders_multi_fallback
    elseif !isnothing(fetch_single_func)
        @warn "ccxt funcs: fetch orders func single fallback (requires `ids` as kwarg)"
        function ccxt_orders_single(ai; ids, side=BuyOrSell, kwargs...)
            out = pylist()
            sym = raw(ai)
            @sync for id in ids
                # NOTE: don't pass `side` when passing `id`
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

function create_order_func(exc::Exchange, func, args...; kwargs...)
    _execfunc(func, args...; kwargs...)
end

@doc "Sets up the [`create_order`](@ref) closure for the ccxt exchange instance."
function ccxt_create_order_func!(a, exc)
    func = first(exc, :createOrderWs, :createOrder)
    @assert !isnothing(func) "$(nameof(exc)) doesn't have a `create_order` function"
    a[:live_send_order_func] = ccxt_create_order(args...; kwargs...) = create_order_func(exc, func, args...; kwargs...)
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

function watch_positions_handler(exc::Exchange, ais, args...; f_push, kwargs...)
    corogen() = exc.watchPositions(_syms(ais), args...; kwargs...)
    stream_handler(corogen, f_push)
end

function watch_balance_handler(exc::Exchange, args...; f_push, kwargs...)
    corogen() = exc.watchBalance(args...; kwargs...)
    parse_and_push(v) = _parse_balance(exc, v) |> f_push
    stream_handler(corogen, parse_and_push)
end

function fetch_balance_func(exc::Exchange, args...; timeout, kwargs...)
    _fetch_balance(exc, args...; timeout, kwargs...)
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
        @warn "ccxt: request timed out" resp eid base_timeout[] f = @caller 10
        base_timeout[] += if timeout > Second(0)
            round(timeout, Second, RoundUp)
        else
            Second(1)
        end
        nothing
    elseif resp isa Exception
        @warn "ccxt: request error" resp eid f = @caller 10
        pre_timeout[] += Second(1)
        nothing
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
                nothing
            else
                timeout = promote(timeout, base_timeout[]) |> sum
                sleep(pre_timeout[])
                out = positions_func(exc, ais; timeout, kwargs...)
                out = handle_list_resp(eid, out, timeout, pre_timeout, base_timeout)
                if !isnothing(out)
                    default_side_func(resp) = _last_posside(_matching_asset(resp, eid, ais))
                    _filter_positions(out, eid, side; default_side_func)
                end
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
                        if !isnothing(p)
                            last_side = _last_posside(ai)
                            default_side_func(_) = last_side
                            p_side = posside_fromccxt(p, eid; default_side_func)
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

cancel_loop_func(exc, cancel_single_f) = begin
    cancel_loop(ids; symbol) = @sync for id in ids
        @async _execfunc(cancel_single_f, id; symbol)
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
            ccxt_cancel_single(ai; side=nothing, ids=()) = _cancel_orders(ai, side, ids, orders_f, cancel_loop_func(exc, cancel_single_f))
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
        ccxt_all_orders_func(ai, args...; kwargs...) = begin
            sym = ai isa AssetInstance ? raw(ai) : nothing
            _execfunc(orders_func, sym, args...; kwargs...)
        end
        ccxt_oc_func(ai, args...; kwargs...) = _tryfetchall(a, ccxt_all_orders_func, ai, args...; kwargs...)
        if open
            this_func = ccxt_open_orders_func(args...; kwargs...) = ccxt_oc_func(args...; kwargs...)
            isopen_func(o) = !_ccxtisopen(o, eid)
            ccxt_open_orders(ai, args...; kwargs...) = _fetch_orders(ai, this_func;
                eid, pred_funcs=(isopen_func,), kwargs...)
        else
            this_func = ccxt_closed_orders_func(args...; kwargs...) = ccxt_oc_func(args...; kwargs...)
            isclosed_func(o) = _ccxtisopen(o, eid)
            ccxt_closed_orders(ai, args...; kwargs...) = _fetch_orders(ai, this_func;
                eid, pred_funcs=(isclosed_func,), kwargs...)
        end
    else
        orders_func = get(a, :live_orders_func, nothing)
        @assert !isnothing(orders_func) "`live_orders_func` must be set before `live_$(names.oc)_orders_func`"
        pred_func(o) = pyeq(Bool, resp_order_status(o, eid), @pyconst("open"))
        status_pred_func = open ? pred_func : !pred_func
        this_func_fallback(ai; ids=(), kwargs...) = begin
            out = pylist()
            all_orders = orders_func(ai; ids, kwargs...)
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
        function mytrades_wrapped(ai; since=nothing, params=nothing)
             _execfunc(mytrades_func, raw(ai); _skipkwargs(; since, params)...)
        end
        function ccxt_my_trades(ai; since=nothing, params=nothing)
            _tryfetchall(a, mytrades_wrapped, ai; since, params)
        end
    else
        @warn "$(nameof(exc)) does not have a method to fetch account trades (trades will be emulated)"
    end
end

@doc """ Retrieves trades for an order or determines the start date for fetching trades.

$(TYPEDSIGNATURES)

Attempts to find trades associated with a given order ID. If trades are not found, it defaults to fetching trades from the last day or a specified `since` date. This function is useful for ensuring that trades are fetched even if the order details do not include them.

"""
find_trades_or_since(a, ai, id::String)::Tuple{DateTime,Option{Py}} = begin
    orderbyid_func = @something first(exchange(ai), :fetchOrderWs, :fetchOrder) Returns(())
    orders_func = a[:live_orders_func]
    closedords_func = a[:live_closed_orders_func]
    default_since() = @something findorder(ai, id; property=:date) _last_trade_date(ai)
    try
        eid = exchangeid(ai)
        ords = @lget! _order_byid_resp_cache(a, ai) id _execfunc(
            orderbyid_func, id, raw(ai)
        ) |> resp_to_vec
        if isemptish(ords)
            ords = @lget! _orders_resp_cache(a, ai) id _execfunc(
                orders_func, ai; ids=(id,)
            ) |> resp_to_vec
            if isemptish(ords) # its possible for the order to not be present in
                # the fetch orders function if it is closed
                ords = @lget! _closed_orders_resp_cache(a, ai) id _execfunc(
                    closedords_func, ai; ids=(id,)
                ) |> resp_to_vec
            end
        end
        if isemptish(ords)
            @debug "live order trades: couldn't fetch trades (default to last day trades)" _module = LogCcxtFuncs order = id ai = raw(ai) exc = nameof(exchange(ai)) since = _last_trade_date(ai)
            return default_since(), nothing
        else
            o = if isdict(ords)
                ords
            elseif islist(ords)
                first(ords)
            else
                @error "live order trades: unexpected return value" id ords
                return default_since(), nothing
            end
            trades_resp = resp_order_trades(o, eid)
            if isemptish(trades_resp)
                return @something(
                    resp_order_timestamp(o, eid),
                    default_since()
                ), nothing
            else
                return DateTime(0), trades_resp
            end
        end
    catch
        @debug_backtrace LogCcxtFuncs
        return default_since(), nothing
    end
end

resp_to_vec(resp) =
    if isnothing(resp) || ismissing(resp)
        []
    elseif resp isa Exception
        @debug "ccxt func error" exception = resp @caller
        []
    elseif isdict(resp)
        [resp]
    elseif islist(resp)
        [resp...]
    end

@doc """ Fetches trades for an order from a specified date.

$(TYPEDSIGNATURES)

Iterates through trades history, starting from a given `since` date, to find trades associated with a specific order ID. This function is useful for retrieving trades that occurred after a certain date.

"""
find_trades_since(a, ai, id_str::String; exc, since, params) = begin
    mytrades_func = a[:live_my_trades_func]
    since = @something since let
        (this_since, trades_resp) = find_trades_or_since(a, ai, id_str)
        if !isemptish(trades_resp)
            # We found the matching order, and it holds the trades in its structure
            return trades_resp
        else
            this_since
        end
    end
    trades_resp = pylist()
    trades_cache = _trades_resp_cache(a, ai)
    since -= Second(1)
    since_bound = since - round(a[:max_order_lookback], Millisecond)
    while since > since_bound
        resp = @lget! trades_cache since begin
            this_resp = _execfunc(mytrades_func, ai; _skipkwargs(; since=dtstamp(since), params)...)
            # NOTE: this can fail if the order id (`order` key is not set/none in the trades structure)
            this_trades = _ordertrades(this_resp, exc, ((x) -> string(x) == id_str))
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
    order_trades_func = first(exc, :fetchOrderTradesWs, :fetchOrderTrades)
    a[:live_order_trades_func] = if !isnothing(order_trades_func)
        ccxt_order_trades(ai, id; since=nothing, params=nothing) = begin
            cache = _order_trades_resp_cache(a, ai)
            @lget! cache id _execfunc(
                order_trades_func;
                symbol=raw(ai), id, _skipkwargs(; since, params)...
            ) |> resp_to_vec
        end
    else
        mytrades_func = a[:live_my_trades_func]
        ccxt_order_trades_fallback(ai, id; since=nothing, params=nothing) = begin
            # Filter recent trades history for trades matching the order
            @debug "fetch order trades: from cache" _module = LogTradeFetch ai id
            trades_cache = _trades_resp_cache(a, ai)
            resp_latest = if mytrades_func isa Function
                @lget! trades_cache LATEST_RESP_KEY _execfunc(
                    mytrades_func, ai; _skipkwargs(; params)...
                ) |> resp_to_vec
            end
            id_str = string(id)
            trades_resp = if isemptish(resp_latest)
                @debug "fetch order trades: emptish" _module = LogTradeFetch ai id
                []
            else
                # NOTE: this can fail if the trade struct `order` field is none/empty
                this_trades = _ordertrades(resp_latest, exc, ((x) -> string(x) == id_str))
                if isnothing(this_trades)
                    @debug "fetch order trades: empty filtered" _module = LogTradeFetch ai id
                    []
                else
                    Any[this_trades...]
                end
            end
            if isemptish(trades_resp)
                @debug "fetch order trades: fetch since" _module = LogTradeFetch ai id
                # Fallback to fetching trades history using since
                find_trades_since(a, ai, id_str; exc, since, params)
            else
                return trades_resp
            end
        end
    end
end

@doc "Sets up the [`fetch_candles`](@ref) closure for the ccxt exchange instance."
function ccxt_fetch_candles_func!(a, exc)
    ohlcv_func = first(exc, :fetchOHLCVWs, :fetchOHLCV)
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
