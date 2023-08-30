using .Executors: AnyLimitOrder
using .PaperMode: create_sim_limit_order
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
    eid = exchangeid(ai)
    _ccxtisopen(resp) ||
        get_float(resp, "filled") > ZERO ||
        begin
            @warn "Order is not open, and does not appear to be (partially) fillled, refusing construction."
            return nothing
        end
    type = let ot = ordertype_fromtif(resp, eid)
        if isnothing(ot)
            t
        else
            side = @something _orderside(resp, eid) orderside(t)
            pos = posside(t)
            Order{ot{side},<:AbstractAsset,<:ExchangeID,typeof(pos)}
        end
    end
    amount = resp_order_amount(resp, eid, amount, Val(:amount); ai)
    price = resp_order_price(resp, eid, price, Val(:price); ai)
    loss = resp_order_loss_price(resp, eid)
    profit = resp_order_profit_price(resp, eid)
    date = @something pytodate(resp, eid) now()
    id = @something _orderid(resp, eid) begin
        @warn "Missing order id for ($(nameof(s))@$(raw(ai))), defaulting to price-time hash"
        string(hash((price, date)))
    end
    o = let f = construct_order_func(type)
        f(s, type, ai; id, amount, date, type, price, loss, profit, kwargs...)
    end
    if isnothing(o)
        @warn "Exchange order created (id: $(resp_order_id(resp, eid))), but couldn't sync locally, $(nameof(s)) $(raw(ai))"
    else
        set_active_order!(s, ai, o)
    end
    return o
end

function create_live_order(
    s::LiveStrategy,
    ai::AssetInstance,
    args...;
    t,
    amount,
    price=lastprice(ai),
    exc_kwargs=(),
    kwargs...,
)
    resp = live_send_order(s, ai, t, args...; amount, price, exc_kwargs...)
    create_live_order(s, resp, ai; amount, price, t, kwargs...)
end
