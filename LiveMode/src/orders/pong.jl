using .Executors: AnyLimitOrder

@doc "Creates a live limit order."
function pong!(
    s::NoMarginStrategy{Live},
    ai,
    t::Type{<:AnyLimitOrder};
    amount,
    price=lastprice(ai),
    waitfor=Second(1),
    order_waitfor=Second(10),
    trades_fetch_kwargs=(),
    orders_fetch_kwargs=(),
    kwargs...,
)::Union{<:Trade,Nothing,Missing}
    watch_trades!(s, ai; fetch_kwargs=trades_fetch_kwargs) # ensure trade watcher is running
    watch_orders!(s, ai; fetch_kwargs=orders_fetch_kwargs) # ensure orders watcher is running
    o = create_live_order(s, ai; t, amount, price, kwargs...)
    isnothing(o) && return nothing
    order_trades = attr(o, :trades)
    # Trade might already have been processed from tasks
    if !isempty(order_trades) ||
        # this should wait for the order to be closed
        (
        (
            o isa AnyImmediateOrder && (waitfororder(s, ai, o; waitfor=order_waitfor); true)
        ) ||
        # otherwise wait a little in case the there is already a fill for the gtc order
        waitfortrade(s, ai, o; waitfor) > 0
    ) && !isempty(order_trades)
        return last(order_trades)
    else
        return missing
    end
end

@doc "Creates a live market order."
function pong!(
    s::NoMarginStrategy{Live},
    ai,
    t::Type{<:AnyMarketOrder};
    amount,
    order_waitfor=Second(10),
    kwargs...,
)
    watch_trades!(s, ai) # ensure trade watcher is running
    watch_orders!(s, ai) # ensure orders watcher is running
    o = create_live_order(s, ai; t, amount, price=lastprice(ai))
    isnothing(o) && return nothing
    order_trades = trades(o)
    if !isempty(order_trades) ||
        (waitfororder(s, ai, o; waitfor=order_waitfor); !isempty(order_trades))
        last(order_trades)
    else
        nothing
    end
end

@doc "Cancel orders for a particular asset instance."
function pong!(
    s::Strategy{Live},
    ai::AssetInstance,
    ::CancelOrders;
    t::Type{<:OrderSide}=Both,
    waitfor=Second(5),
    confirm=false,
)
    if live_cancel(s, ai; side=t, confirm, all=true)::Bool
        confirm || begin
            waitfor_closed(s, ai, waitfor; t)
            if orderscount(s, ai, t) > 0
                @warn "Unexpected orders state $(raw(ai)), checking open orders from $(nameof(exchange(ai)))."
                if try
                    isempty(fetch_open_orders(s, ai, side=t))
                catch
                    false
                end
                    delete!(s, ai, t)
                    return true
                else
                    @error "Deleted orders for side $t, but still tracking $(length(orderscount(s, ai, t))) orders for $(raw(ai))@$(nameof(s))"
                    return false
                end
            end
        end
        # remember to stop tasks
        stop_asset_tasks(s, ai)
        true
    else
        false
    end
end
