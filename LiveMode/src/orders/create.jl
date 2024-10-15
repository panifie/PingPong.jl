using .Executors: AnyLimitOrder
using .PaperMode: create_sim_limit_order
using .PaperMode.SimMode: construct_order_func
using .Executors.Instruments: AbstractAsset
using .OrderTypes: ordertype, MarketOrderType, GTCOrderType, ForcedOrderType
using .Lang: filterkws

function isactive(s::Strategy, ai::AssetInstance, resp::Py, eid::EIDType; fetched=false)
    isopen, status = _ccxtisopen(resp, eid, Val(:status))
    hasfill = resp_order_filled(resp, eid) > 0.0
    oid = resp_order_id(resp, eid, String)
    hasid = !isempty(oid)

    @debug "create order: isopen" _module = LogCreateOrder isopen hasfill oid hasid
    if !isopen && !hasfill && !hasid
        @warn "create order: refusing" ai oid isopen hasfill hasid
        return false, resp
    else
        status = resp_order_status(resp, eid)
        if (!_ccxtisstatus(resp, eid) && !fetched)
            if isprocessed_order(s, ai, oid)
                fetched_resp = fetch_orders(s, ai; ids=(oid,))
                if hasels(fetched_resp)
                    this_resp = first(fetched_resp)
                    return if resp_order_id(this_resp, eid) != oid
                        @error "create order: wrong id" oid this_resp
                        false, this_resp
                    else
                        isactive(s, ai, this_resp, eid; fetched=true)
                    end
                else
                    @debug "create order: order not found on exchange (canceled?)" _module = LogCreateOrder ai oid hasfill hasid fetched_resp
                    return false, resp
                end
            else
                @warn "create order: unknown status" ai oid hasfill hasid resp status
                return hasid, resp
            end
        elseif _ccxtisstatus(status, "canceled", "rejected", "expired") || fetched
            @warn "create order: $status" ai oid hasfill hasid
            return false, resp
        end
    end
    return true, resp
end

@doc """ Creates a live order.

$(TYPEDSIGNATURES)

This function is designed to create a live order on a given strategy and asset instance.
It verifies the response from the exchange and constructs the order with the provided parameters.
If the order fails to construct and is marked as synced, it attempts to synchronize the strategy and universe cash, and then retries order creation.
Finally, if the order is marked as active, the function sets it as the active order.
"""
function _create_live_order(
    s::LiveStrategy,
    ai::AssetInstance,
    resp;
    t,
    price,
    amount,
    synced=true,
    activate=true,
    skipcommit=false,
    kwargs...,
)
    if isnothing(resp)
        @warn "create order: empty response ($(raw(ai)))"
        return nothing
    end

    eid = side = type = loss = profit = date = id = nothing
    try
        eid = exchangeid(ai)
        status = resp_order_status(resp, eid)
        side = @something _orderside(resp, eid) orderside(t)
        @debug "create order: parsing" _module = LogCreateOrder status filled =
            resp_order_filled(resp, eid) > 0.0 id = resp_order_id(resp, eid) side
        isopen_flag, resp = isactive(s, ai, resp, eid)
        if !isopen_flag
            return nothing
        end
        this_order_type(ot) = begin
            pos = @something posside(t) posside(ai) Long()
            Order{ot{side},<:AbstractAsset,<:ExchangeID,typeof(pos)}
        end
        type = let ot = ordertype_fromccxt(resp, eid)
            if isnothing(ot)
                if t isa Type{<:Order}
                    t
                else
                    @something ordertype_fromtif(resp, eid) (
                        if _ccxtisstatus(resp, "closed", eid)
                            MarketOrderType
                        else
                            GTCOrderType
                        end |> this_order_type
                    )
                end
            else
                this_order_type(ot)
            end
        end
        amount = resp_order_amount(resp, eid, amount, Val(:amount); ai)
        price = resp_order_price(resp, eid, price, Val(:price); ai)
        loss = resp_order_loss_price(resp, eid)
        profit = resp_order_profit_price(resp, eid)
        date = let this_date = @something pytodate(resp, eid) now()
            # ensure order pricetime doesn't clash
            while haskey(s, ai, (; price, time=this_date), side)
                this_date += Millisecond(1)
            end
            this_date
        end
        id = @something _orderid(resp, eid) begin
            @warn "create order: missing id (default to pricetime hash)" ai = raw(ai) s = nameof(
                s
            )
            string(hash((price, date)))
        end
    catch
        @error "create order: parsing failed" resp
        @debug_backtrace LogCreateOrder
        return nothing
    end
    o = let f = construct_order_func(type)
        function create(; skipcommit)
            @debug "create order: local" _module = LogCreateOrder ai id amount date type price leverage(
                ai
            ) loss profit @caller(20)
            f(
                s,
                type,
                ai;
                id,
                amount,
                date,
                type,
                price,
                loss,
                profit,
                skipcommit,
                kwargs...,
            )
        end
        o = create(; skipcommit)
        if isnothing(o) && synced
            o = findorder(s, ai; resp, side)
            if isnothing(o)
                @warn "create order: can't construct (back-tracking)" id = resp_order_id(
                    resp, eid
                ) resp_order_status(resp, eid) ai = raw(ai) cash(ai) s = nameof(s) t
            end
        end
        if isnothing(o)
            @debug "create order: retrying (no commits)" _module = LogCreateOrder ai = raw(ai) side = posside(t)
            o = @inlock ai create(skipcommit=true)
        end
        o
    end
    if isnothing(o)
        @error "create order: failed to sync" id ai = raw(ai) cash(ai) amount s = nameof(s) type
        @debug "create order: failed sync response" _module = LogCreateOrder resp
        return nothing
    elseif activate
        @debug "create order: activating order" _module = LogCreateOrder id resp_order_status(resp, eid) resp_order_filled(resp, eid) resp_order_remaining(resp, eid) resp_order_type(resp, eid)
        state = set_active_order!(s, ai, o; ap=resp_order_average(resp, eid))
        # Perform a trade if the order has been filled instantly
        function not_filled()
            !isequal(ai, resp_order_filled(resp, eid), filled_amount(o), Val(:amount))
        end
        if not_filled()
            @debug "create order: scheduling emulation" _module = LogCreateOrder resp_order_filled(resp, eid) filled_amount(o) not_filled()
            func() =
                if not_filled()
                    t = @inlock ai emulate_trade!(s, o, ai; state.average_price, resp)
                end
            sendrequest!(ai, resp_order_timestamp(resp, eid), func)
        end
    end
    event!(
        ai,
        AssetEvent,
        :order_created,
        s;
        order=o,
        req_type=t,
        req_price=price,
        req_amount=amount,
    )
    @debug "create order: done" _module = LogCreateOrder committed(o) o.amount ordertype(o)
    return o
end

@doc """ Sends and constructs a live order.

$(TYPEDSIGNATURES)

This function sends a live order using the provided parameters and constructs it based on the response received.

"""
function _create_live_order(
    s::LiveStrategy,
    ai::AssetInstance,
    args...;
    t,
    amount,
    price=lastprice(s, ai, t),
    exc_kwargs=(),
    skipchecks=false,
    kwargs...,
)
    @debug "create order: sending request" _module = LogCreateOrder ai t price amount f = @caller
    resp = try
        live_send_order(
            s,
            ai,
            t,
            args...;
            skipchecks,
            amount,
            price,
            withoutkws(:date; kwargs=exc_kwargs)...,
        )
    catch
        @debug_backtrace LogCreateOrder
        @error "create order: send failed" ai t amount price
        return nothing
    end
    if resp isa Exception
        @error "create order: send failed" ai t amount price exception = resp
    else
        @debug "create order: after request" _module = LogCreateOrder ai t price amount f = @caller() resp
        _create_live_order(s, ai, resp; amount, price, t, kwargs...)
    end
end

function create_live_order(s, ai, args...; waitfor=Second(15), kwargs...)
    ans = Ref{Union{Order,Nothing,Exception}}(nothing)
    func() = (ans[] = (@inlock ai _create_live_order(s, ai, args...; kwargs...)))
    sendrequest!(ai, now(), func, waitfor)
    ans[]
end
