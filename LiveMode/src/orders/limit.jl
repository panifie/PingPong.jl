@doc """ Places a limit order and waits for its completion.

$(TYPEDSIGNATURES)

This function creates a live limit order and then waits for it to either be filled or canceled, depending on the waiting time provided.
It handles immediate orders differently, in such cases it waits for the order to be closed.
If an order fails or is canceled, the function returns the relevant status.

"""
function _live_limit_order(s::LiveStrategy, ai, t; skipchecks=false, amount, price, waitfor, synced, kwargs)
    local o, order_trades
    # NOTE: necessary locks to prevent race conditions between balance/positions updates
    # and order creation
    @lock ai @lock s begin
        o = create_live_order(s, ai; skipchecks, t, amount, price, exc_kwargs=kwargs)
        isnothing(o) && return nothing
        order_trades = attr(o, :trades)
    end
    @debug "pong limit order: waiting" _module = LogCreateOrder waitfor
    @timeout_start
    # if immediate should wait for the order to be closed
    if isimmediate(o)
        if waitfororder(s, ai, o; waitfor=@timeout_now) && !isempty(order_trades)
            last(order_trades)
        elseif !haskey(s, ai, o)
            @debug "pong limit order: immediate order failed" _module = LogCreateOrder o.id
            nothing
        else
            if synced
                @lock ai @lock s _force_fetchtrades(s, ai, o)
            end
            if isempty(order_trades)
                if haskey(s, ai, o)
                    missing
                else
                    @debug "pong limit order: immediate order failed" _module = LogCreateOrder o.id
                end
            else
                last(order_trades)
            end
        end
    elseif !isempty(order_trades)
        last(order_trades)
        # otherwise wait a little in case the there is already a fill for the gtc order
    elseif waitfortrade(s, ai, o; waitfor=@timeout_now)
        last(order_trades)
    elseif haskey(s, ai, o)
        if synced
            @lock ai @lock s _force_fetchtrades(s, ai, o)
        end
        if isempty(order_trades)
            if haskey(s, ai, o)
                @debug "pong limit order: no trades yet" _module = LogCreateOrder synced
                missing
            end
        else
            last(order_trades)
        end
    else
        @debug "pong limit order: canceled or failed" _module = LogCreateOrder
    end
end
