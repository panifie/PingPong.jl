using .Misc.Lang: @lget!, @deassert, Option
using .Python: @py, pydict
using .Executors: AnyGTCOrder, AnyMarketOrder, AnyIOCOrder, AnyFOKOrder, AnyPostOnlyOrder

function live_cancel(s, ai; ids=(), side=Both, confirm=false, all=false, since=nothing)
    (func, kwargs) = if all
        (cancel_all_orders, (;))
    else
        (cancel_orders, (; ids, side))
    end
    done = try
        resp = func(s, ai; kwargs...)
        if resp isa PyException
            @warn "Couldn't cancel orders for $(raw(ai)) $resp"
            false
        elseif isnothing(resp)
            true
        elseif pyisinstance(resp, pybuiltins.dict)
            pyisTrue(get_py(resp, "code") == @pystr("0"))
        else
            false
        end
    catch e
        @warn "Couldn't cancel orders for $(raw(ai)) $e"
        return false
    end
    if done && confirm
        open_orders = fetch_open_orders(
            s, ai; since=isnothing(since) ? nothing : TimeTicks.dtstamp(since)
        )
        if side == Both
            isempty(open_orders) || return false
        else
            side_str = _ccxtorderside(side)
            for o in open_orders
                pyisTrue(get_py(o, "side") == side_str) && return false
            end
        end
    end
    done
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

function _ccxttif(exc, type)
    if type <: PostOnlyOrder
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

const TriggerOrderTuple = NamedTuple{(:type, :price, :trigger)}

function trigger_dict(exc, v)
    out = pydict()
    out[@pystr("type")] = _ccxtordertype(exc, v.type)
    out[@pystr("price")] = pyconvert(Py, v.price)
    out[@pystr("triggerPrice")] = pyconvert(Py, v.trigger)
    out
end

function live_send_order(
    s::LiveStrategy,
    ai,
    t=GTCOrder{Buy},
    args...;
    amount,
    price=lastprice(ai),
    retries=0,
    post_only=false,
    reduce_only=false,
    stop_trigger=nothing,
    profit_trigger=nothing,
    stop_loss::Option{TriggerOrderTuple}=nothing,
    take_profit::Option{TriggerOrderTuple}=nothing,
    kwargs...,
)
    sym = raw(ai)
    exc = exchange(ai)
    side = _ccxtorderside(t)
    type = _ccxtordertype(exc, t)
    tif = _ccxttif(exc, t)
    tif_k = @pystr(time_in_force_key(exc))
    tif_v = @pystr(time_in_force_value(exc, tif))
    params = LittleDict{Py,Any}(@pystr(k) => pyconvert(Py, v) for (k, v) in kwargs)
    get!(params, tif_k, tif_v)
    function supportmsg(feat)
        @warn "$feat requested, but exchange $(nameof(exc)) doesn't support it"
    end
    get!(params, @pystr("postOnly"), post_only) &&
        (has(exc, :createPostOnlyOrder) || supportmsg("Post Only"))
    get!(params, @pystr("reduceOnly"), reduce_only) &&
        (has(exc, :createReduceOnlyOrder) || supportmsg("Reduce Only"))
    isnothing(stop_loss) || let stop_k = @pystr("stopLoss")
        haskey(params, stop_k) || (params[stop_k] = trigger_dict(exc, stop_loss))
    end
    isnothing(take_profit) || let take_k = @pystr("takeProfit")
        haskey(params, take_k) || (params[take_k] = trigger_dict(exc, take_profit))
    end
    isnothing(stop_trigger) || let stop_k = @pystr("stopLossPrice")
        haskey(params, stop_k) || (params[stop_k] = pyconvert(Py, stop_trigger))
    end
    isnothing(profit_trigger) || let take_k = @pystr("takeProfitPrice")
        haskey(params, take_k) || (params[take_k] = pyconvert(Py, profit_trigger))
    end

    resp = create_order(s, sym, args...; side, type, price, amount, params)
    while resp isa Exception && retries > 0
        retries -= 1
        resp = create_order(s, sym, args...; kwargs...)
    end
    if resp isa PyException
        @warn "Couldn't create order $(sym) on $(nameof(exchange(ai))) $(resp)"
        return nothing
    end
    resp
end
