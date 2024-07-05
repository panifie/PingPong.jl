import .Executors: cancel!
@doc """ Cancels live orders on an exchange.

$(TYPEDSIGNATURES)

The function cancels either all live orders or specified ones based on the side (buy/sell).
It can optionally confirm if the cancellation was successful.
If the confirmation fails or if any error occurs during the process, a warning is issued and the function returns false.

"""
function live_cancel(s, ai; ids=(), side=BuyOrSell, confirm=false, since=nothing)
    eid = exchangeid(ai)
    all = isempty(ids)
    (func, kwargs) = if side === BuyOrSell && all
        (cancel_all_orders, (;))
    else
        (
            cancel_orders,
            (;
                ids=if all
                    (resp_order_id(resp, eid) for resp in fetch_open_orders(s, ai; side))
                else
                    ids
                end,
                side,
            ),
        )
    end
    done = try
        resp = func(s, ai; kwargs...)
        if resp isa PyException
            @warn "live cancel: failed" ai = raw(ai) resp @caller
            false
        elseif isnothing(resp)
            @debug "live cancel: response is nothing" _module = LogCancelOrder @caller
            true
        elseif pyisinstance(resp, pybuiltins.dict)
            if resptobool(exchange(ai), resp)
                true
            else
                @warn "live cancel: failed (wrong status code)" ai = raw(ai) resp
                false
            end
        elseif pyisinstance(resp, pybuiltins.list)
            true
        else
            @warn "live cancel: failed (unhandled response)" ai = raw(ai) resp
            false
        end
    catch
        @warn "live cancel: failed (exception)" ai = raw(ai)
        @debug_backtrace LogCancelOrder
        return false
    end
    if done && confirm
        open_orders = fetch_open_orders(s, ai; since=if !isnothing(since)
            dtstamp(since)
        end)
        if side === BuyOrSell
            isempty(open_orders) || begin
                @warn "live cancel: confirm failed (both sides)"
                return false
            end
        else
            side_str = _ccxtorderside(side)
            for o in open_orders
                pyeq(Bool, resp_order_side(o, eid), side_str) && begin
                    @warn "live cancel: confirm failed" side
                    return false
                end
            end
        end
    end
    done
end

function cancel!(s::LiveStrategy, o::Order, ai; kwargs...)
    if isqueued(o, s, ai)
        decommit!(s, o, ai, true)
        delete!(s, ai, o)
        st.ping!(s, o, err, ai)
        event!(ai, AssetEvent, :order_local_cancel, s; order=o, err)
    end
end