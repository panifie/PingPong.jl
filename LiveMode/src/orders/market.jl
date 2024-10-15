@doc """ Places a market order and waits for its completion.

$(TYPEDSIGNATURES)

This function creates a live market order and then waits for it to either be filled or canceled, depending on the waiting time provided.
The function returns the last trade if any trades have occurred, otherwise it returns a `missing` status.

"""
function _live_market_order(s, ai, t; skipchecks=false, amount, synced, waitfor, kwargs)
    local o, order_trades
    # NOTE: necessary locks to prevent race conditions between balance/positions updates
    # and order creation
    order_trades = begin
        o = create_live_order(
            s, ai; t, amount, price=lastprice(ai, Val(:history)), exc_kwargs=kwargs, skipchecks
        )
        if !(o isa Order)
            return nothing
        else
            hold!(s, ai, o)
        end
        @deassert o isa AnyMarketOrder{orderside(t)} o
        @debug "market order: created" _module = LogCreateOrder id = o.id o.amount t hasorders(s, ai, o.id) cash(ai)
        trades(o)
    end
    @timeout_start
    if !isempty(order_trades) ||
       (waitorder(s, ai, o; waitfor=@timeout_now) && !isempty(order_trades))
        last(order_trades)
    elseif waittrade(s, ai, o; waitfor=@timeout_now, force=synced)
        last(order_trades)
    elseif isempty(order_trades)
        if isactive(s, ai, o)
            if synced
                live_sync_open_orders!(s, ai, side=orderside(o), exec=true)
                if !isempty(order_trades)
                    last(order_trades)
                elseif isactive(s, ai, o)
                    @debug "market order: no trades yet (synced)" _module = LogCreateOrder
                    missing
                end
            else
                @debug "market order: no trades yet" _module = LogCreateOrder
                missing
            end
        else
            @debug "market order: failed" _module = LogCreateOrder synced
            nothing
        end
    else
        last(order_trades)
    end
end
