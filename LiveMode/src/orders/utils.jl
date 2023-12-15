using .Misc.Lang: @lget!, @deassert, Option
using .Python: @py, pydict
using .Executors:
    AnyGTCOrder, AnyMarketOrder, AnyLimitOrder, AnyIOCOrder, AnyFOKOrder, AnyPostOnlyOrder
using LRUCache

@doc "Represents the state of a live order comprising order details, a lock, trade hashes, an update hash, and average price."
const LiveOrderState = NamedTuple{
    (:order, :lock, :trade_hashes, :update_hash, :average_price),
    Tuple{Order,ReentrantLock,Vector{UInt64},Ref{UInt64},Ref{DFT}},
}

@doc "A dictionary mapping asset strings to their corresponding live order states."
const AssetOrdersDict = LittleDict{String,LiveOrderState}

@doc """ Retrieves active orders for a live strategy.

$(TYPEDSIGNATURES)

Returns a dictionary of active orders for all asset instances in a live strategy.
If no dictionary exists, a new one is created.

"""
function active_orders(s::LiveStrategy)
    @lget! attrs(s) :live_active_orders Dict{AssetInstance,AssetOrdersDict}()
end
function active_orders(s::LiveStrategy, ai)
    ords = active_orders(s)
    @lget! ords ai AssetOrdersDict()
end

@doc "An lru cache of recently processed orders ids."
const RecentOrdersDict = LRUCache.LRU{String,Nothing}
@doc """ Retrieves recent orders ids for a live strategy.

$(TYPEDSIGNATURES)

Returns a dictionary of recent orders ids for a given asset instance.

"""
function recent_orders(s::LiveStrategy, ai)
    lro = @lget! attrs(s) :live_recent_orders Dict{AssetInstance,RecentOrdersDict}()
    @lget! lro ai RecentOrdersDict(maxsize=100)
end

@doc """ Computes the average price of an order.

$(TYPEDSIGNATURES)

It calculates the average price by summing the value and amount of each trade in the order,
and then dividing the total value by the total amount.
If no trades exist, it returns the original order price.

"""
avgprice(o::Order) =
    let order_trades = trades(o)
        isempty(order_trades) && return o.price
        val = zero(DFT)
        amt = zero(DFT)
        for t in order_trades
            val += t.value
            amt += t.amount
        end
        return val / amt
    end


@doc "Stores and order id in the recently orders cache."
record_order!(s::LiveStrategy, ai, id::String) =
    let lro = recent_orders(s, ai)
        lro[id] = nothing
    end
@doc "Stores and order in the recently orders cache."
record_order!(s::LiveStrategy, ai, o::Order) = record_order!(s, ai, o.id)
@doc "Tests if an order id has been recently processed."
isprocessed_order(s::LiveStrategy, ai, id::String) = id ∈ keys(recent_orders(s, ai))
@doc "Tests if an order has been recently processed."
isprocessed_order(s::LiveStrategy, ai, o::Order) = isprocessed_order(o.id)

@doc """ Registers an active order in a live strategy.

$(TYPEDSIGNATURES)

This function sets an order as active for a given asset in a live strategy.
The order's state includes a lock, trade hashes, an update hash, and the average price.
The function ensures that the trade and orders watchers are running for the asset.

"""
function set_active_order!(s::LiveStrategy, ai, o; ap=avgprice(o))
    @debug "orders: set active" o.id
    state = @lget! active_orders(s, ai) o.id (;
        order=o,
        lock=ReentrantLock(),
        trade_hashes=UInt64[],
        update_hash=Ref{UInt64}(0),
        average_price=Ref(iszero(ap) ? avgprice(o) : ap),
    )
    watch_trades!(s, ai) # ensure trade watcher is running
    watch_orders!(s, ai) # ensure orders watcher is running
    state
end

@doc "Remove order from the set of active orders."
function clear_order!(s::LiveStrategy, ai, o::Order)
    ao = active_orders(s, ai)
    delete!(ao, o.id)
    record_order!(s, ai, o)
end

@doc """ Displays the active orders.

$(TYPEDSIGNATURES)

This function prints the active orders for a given asset in a live strategy.
Each order's id is printed along with its open status.

"""
function show_active_orders(s::LiveStrategy, ai)
    open_orders = fetch_open_orders(s, ai)
    open_ids = Set(resp_order_id.(open_orders))
    active = active_orders(s, ai)
    for id in keys(active)
        println(stdout, string(id, " open: ", id ∈ open_ids))
    end
    flush(stdout)
end

@doc """ Checks if an order is filled and performs actions if it is.

$(TYPEDSIGNATURES)

This macro checks if an order is filled.
If the order is filled, it decommits the order and deletes it from the active orders for a specified asset in a live strategy.

"""
macro _isfilled()
    expr = quote
        # fallback to local
        if isfilled(o)
            decommit!(s, o, ai)
            delete!(s, ai, o)
        end
    end
    esc(expr)
end

@doc """ Waits for all active orders to close.

$(TYPEDSIGNATURES)

This function waits until all active orders for a given asset in a live strategy are closed or until a specified timeout is reached.
If the orders are not closed by the time the timeout is reached, it attempts to sync the open orders.
If orders remain open after the sync attempt, it signals an error.

"""
function waitfor_closed(
    s::LiveStrategy, ai, waitfor=Second(5); t::Type{<:OrderSide}=Both, synced=true
)
    try
        active = active_orders(s, ai)
        slept = 0
        timeout = Millisecond(waitfor).value
        success = true
        @debug "wait ord close: waiting" ai = raw(ai) side = t
        while true
            isactive(s, ai; active, side=t) || begin
                @debug "wait ord close: done" ai = raw(ai)
                break
            end
            slept < timeout || begin
                success = false
                @debug "wait ord close: timedout" ai = raw(ai) side = t waitfor f = @caller
                if synced
                    @warn "wait ord close: syncing"
                    live_sync_open_orders!(s, ai; side=t, strict=false, exec=true)
                    success = if isactive(s, ai; side=t)
                        @error "wait ord close: orders still active" side = t n = orderscount(
                            s, ai, t
                        ) length(active_orders(s, ai)) isactive(s, ai; side=t)
                        false
                    else
                        true
                    end
                end
                break
            end
            sleep(0.1)
            slept += 100
        end
        if success
            if orderscount(s, ai, t) > 0
                @debug "wait ord close: syncing(2nd) f" orderscount(s, ai, t)
                live_sync_open_orders!(s, ai; side=t, strict=false, exec=true)
                orderscount(s, ai, t) > 0
            else
                true
            end
        else
            false
        end
    catch
        @debug_backtrace
        false
    end
end

@doc """ Checks if there are active orders for a specific side.

$(TYPEDSIGNATURES)

This function determines if there are active orders for a specific side (Buy/Sell/Both)
for a given asset in a live strategy.

"""
function isactive(s::LiveStrategy, ai; active=active_orders(s, ai), side=Both)
    for state in values(active)
        orderside(state.order) == side && return true
    end
    return false
end

@doc """ Checks if a specific order is active.

$(TYPEDSIGNATURES)

This function determines if a specific limit order is active for a given asset in a live strategy.
"""
function isactive(
    s::LiveStrategy, ai, o::AnyLimitOrder; pt=pricetime(o), active=active_orders(s, ai)
)
    haskey(s, ai, pt, o) && haskey(active, o.id)
end

@doc """ Checks if a specific order is active.

$(TYPEDSIGNATURES)

This function determines if a specific order is active for a given asset in a live strategy.
"""
function isactive(s::LiveStrategy, ai, o; active=active_orders(s, ai), kwargs...)
    haskey(active, o.id)
end
