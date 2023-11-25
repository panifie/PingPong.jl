@doc """ Fetches a live order by id from the exchange.

$(TYPEDSIGNATURES)

This function fetches an order by id from the exchange for an asset.
It first retrieves the order id and status from the response. 
If the status of the order is open, it fetches open orders from the exchange and searches for the order with the given id.
If the order is not found or its status is not open, it fetches closed orders from the exchange and searches for the order with the given id.

"""
function live_order_byid(s::LiveStrategy, ai; resp)
    eid = exchangeid(ai)
    id = resp_order_id(resp, eid, String)
    if isempty(id)
        @warn "Missing order id when trying to fetch an order from ($(raw(ai))@$(nameof(s)))"
        return nothing
    end
    status = resp_order_status(resp, eid)
    status_open = _ccxtisstatus("open", status)
    fetch_resp = if status_open
        fetch_open_orders(s, ai; ids=(id,))
    else
        fetch_closed_orders(s, ai; ids=(id,))
    end
    function _byid(list_resp)
        if islist(fetch_resp) && !isempty(fetch_resp)
            for o in list_resp
                if resp_order_id(o, eid, String) == id
                    return o
                end
            end
        end
    end
    v = _byid(fetch_resp)
    if isnothing(v) && status_open
        fetch_resp = fetch_closed_orders(s, ai; ids=(id,))
        _byid(fetch_resp)
    else
        v
    end
end

# in case a response field seems sus, query a different endpoint for the same data
# might give better info on what's the correct state, example for order amount
# (amount, fallback_resp) = _ccxtvalue_with_fallback(
#     s,
#     ai,
#     resp,
#     "amount",
#     amount;
#     getter=(resp, k, def) -> get_float(resp, k, def, Val(:amount); ai),
# )

@doc """ Returns a value from a live order response with a fallback mechanism.

$(TYPEDSIGNATURES)

This function attempts to fetch a specific value from a live order response. 
If the value does not match the expected default within a given tolerance, 
it fetches the order by its id as a fallback and tries to get the value again. 
A warning is issued if the fetched value still doesn't match the expected default.

"""
function _ccxtvalue_with_fallback(
    s::LiveStrategy, ai, resp, k, def; getter, rtol=0.05, fallback_resp=nothing
)
    v = getter(resp, k, def)
    isapprox(v, def; rtol) || begin
        isnothing(fallback_resp) && begin
            fallback_resp = live_order_byid(s, ai; resp)
        end
        isnothing(fallback_resp) || begin
            v = getter(fallback_resp, k, def)
            isapprox(v, def; rtol) ||
                @warn "Mismatching order about $def (local) $v ($(nameof(exchange(ai))))"
        end
    end
    (v, fallback_resp)
end
