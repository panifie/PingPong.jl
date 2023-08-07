using .Misc.Lang: @lget!, @deassert, Option, @logerror
using .Python: @py

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
            pyisTrue(resp.get("code") == @pystr("0"))
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
                pyisTrue(o.get("side") == side_str) && return false
            end
        end
    end
    done
end

function _checkordertype(exc, sym)
    @assert has(exc, sym) "Exchange $(nameof(exc)) doesn't support $sym orders."
end
function _ccxtordertype(exc, type)
    @pystr if type <: LimitOrder
        _checkordertype(exc, :createLimitOrder)
        "limit"
    elseif type <: MarketOrder
        _checkordertype(exc, :createMarketOrder)
        "market"
    else
        error("Order type $type is not valid.")
    end
end

time_in_force_value(::Exchange, v) = v
time_in_force_key(::Exchange) = "timeInForce"

function _ccxttif(exc, type)
    @pystr if type <: PostOnlyOrder
        @assert has(exc, :createPostOnlyOrder) "Exchange $(nameof(exc)) doesn't support post only orders."
        "PO"
    elseif type <: GTCOrder
        "GTC"
    elseif type <: FOKOrder
        "FOK"
    elseif type <: IOCOrder
        "IOC"
    else
        @warn "Unable to choose time-in-force setting for order type $type (defaulting to GTC)."
        "GTC"
    end
end

function live_create_order(
    s::LiveStrategy,
    ai,
    t=GTCOrder{Buy},
    args...;
    amount,
    price=lastprice(ai),
    retries=0,
    params::Option{D} where {D<:AbstractDict}=nothing,
    kwargs...,
)
    sym = raw(ai)
    exc = exchange(ai)
    side = _ccxtorderside(t)
    type = _ccxtordertype(exc, t)
    tif = _ccxttif(exc, t)
    tif_k = @pystr(time_in_force_key(exc))
    tif_v = @pystr(time_in_force_value(exc, tif))
    if isnothing(params)
        params = LittleDict((tif_k,), (tif_v,))
    else
        params[tif_k] = tif_v
    end
    resp = create_order(s, sym, args...; side, type, price, amount, params, kwargs...)
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
