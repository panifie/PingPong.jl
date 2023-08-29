using .Executors: AnyLimitOrder
using .PaperMode: _asdate, create_sim_limit_order
using .PaperMode.SimMode: construct_order_func
using .Executors.Instruments: AbstractAsset
using .OrderTypes: ordertype

function create_live_order(
    s::LiveStrategy, resp, ai::AssetInstance; t, price, amount, kwargs...
)
    isnothing(resp) && begin
        @warn "trying to create limit order with empty response ($(raw(ai)))"
        return nothing
    end
    _ccxtisopen(resp) ||
        get_float(resp, "filled") > ZERO ||
        begin
            @warn "Order is not open, and does not appear to be (partially) fillled, refusing construction."
            return nothing
        end
    type = let ot = ordertype_fromtif(resp)
        if isnothing(ot)
            t
        else
            side = @something _orderside(resp) orderside(t)
            pos = posside(t)
            Order{ot{side},<:AbstractAsset,<:ExchangeID,typeof(pos)}
        end
    end
    amount = get_float(resp, "amount", amount, Val(:amount); ai)
    price = get_float(resp, "price", price, Val(:price); ai)
    stop = _option_float(resp, "stopLossPrice")
    take = _option_float(resp, "takeProfitPrice")
    date = @something pytodate(resp) now()
    id = @something _orderid(resp) begin
        @warn "Missing order id for ($(nameof(s))@$(raw(ai))), defaulting to price-time hash"
        string(hash((price, date)))
    end
    o = let f = construct_order_func(type)
        f(s, type, ai; id, amount, date, type, price, stop, take, kwargs...)
    end
    if isnothing(o)
        @warn "Exchange order created (id: $(get_py(resp, "id"))), but couldn't sync locally, $(nameof(s)) $(raw(ai))"
    else
        set_active_order!(s, ai, o)
    end
    return o
end

function create_live_order(
    s::LiveStrategy, ai::AssetInstance, args...; t, amount, price=lastprice(ai), kwargs...
)
    resp = live_send_order(s, ai, t, args...; amount, price, kwargs...)
    create_live_order(s, resp, ai; amount, price, t, kwargs...)
end