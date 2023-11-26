_lastupdate!(s, date) = s.attrs[:sim_last_orders_update] = date
_lastupdate(s) = s.attrs[:sim_last_orders_update]
@doc """Checks if the last update date is greater than or equal to the given date and throws an error if not.

$(TYPEDSIGNATURES)

If the last update date is not greater than or equal to the given date, an error with the message "Tried to update orders multiple times on the same date." is thrown.

"""
function _check_update_date(s, date)
    _lastupdate(s) >= date &&
        error("Tried to update orders multiple times on the same date.")
end
using Executors.Instances.DataStructures: SAIterationState
using Simulations.Random: shuffle!

@doc """Pushes all orders from side_orders into all_orders.

$(TYPEDSIGNATURES)

This function pushes all orders from side_orders into all_orders. It collapses all assets into a single array, so what is shuffled is either orders of the same side.

"""
_dopush!(side_orders, all_orders) =
    for (ai, ords) in side_orders
        push!(all_orders, (ai, ords))
    end

@doc """Pushes orders from `ai_orders` into the simulation `s` at the specified `date`.

$(TYPEDSIGNATURES)

This function iterates over each order in `ai_orders` and checks if it is already queued in the simulation `s`.
If not, it calls the `order!` function to add the order to the simulation at the specified `date`.
"""
_dopong!(s, ai, ai_orders, date) =
    for o in collect(ai_orders)
        isqueued(o, s, ai) || continue
        order!(s, o, date, ai)
    end

@doc """Iterates over all pending orders checking for new fills.

$(TYPEDSIGNATURES)

This function iterates over each order in `all_orders` and calls `_dopong!` to add the order to the simulation `s` at the specified `date`.

"""
_doall!(s, all_orders, date) =
    for (ai, ords) in all_orders
        _dopong!(s, ai, ords, date)
    end

@doc """Iterates over all pending orders checking for new fills. 

$(TYPEDSIGNATURES)

If you don't have any callbacks attached to orders,
the outcome is the same as plain `UpdateOrders`. (It is ~10% slower than the basic function.)

The difference between this function and the base one dispatched over `UpdateOrders` is that
the sequence in which the pending orders are evaluated is shuffled. More precisely both buy orders and sell orders
for all assets are collapsed into a single array, therefore what is shuffled is either orders of the same side
_for different assets_, or the precedence between buy and sell _of the same assets_.
This means that if a particular asset has more than one pending buy(sell) order,
their evaluation will be always chained, for example if `A` and `B` are assets, a possible reordering would be:
```
A_buyorder1, A_buyorder2, B_buyorder1, B_buyorder2, A_sellorder1, B_sellorder2
```
Or
```
B_buyorder1, B_buyorder2, A_buyorder1, A_buyorder2 , A_sellorder1, B_sellorder2
```
Or
```
A_sellorder1, B_buyorder1, B_buyorder2, A_buyorder1, A_buyorder2 , B_sellorder2
```
This instead, will never occur:
```
B_buyorder1, A_buyorder1, B_buyorder2, A_buyorder1, A_buyorder2 , B_sellorder2
```
Because the buy orders for B would be detached. The reason why we don't have a finer grained shuffling mechanism
that allows this case is because it would be too slow, and the minimal increase in randomness is not worth it.

Note also that the sequence of evaluation for orders of the same side and asset is always fixed and sorted.
The sorting mirrors the sequence in which the orders would be triggered on the exchange, so for buy orders
the ones with higher price and earlier date are evaluated first, while for sell orders, the ones with a lower price
and still an earlier date. (Check the `lt` functions defined in the `Strategies` module.)
"""
function update!(s::Strategy{Sim}, date, ::UpdateOrdersShuffled)
    _check_update_date(s, date)
    positions!(s, date)
    let buys = orders(s, Buy), sells = orders(s, Sell)
        allorders = Tuple{eltype(s.holdings),Union{valtype(buys),valtype(sells)}}[]
        _dopush!(sells, allorders)
        _dopush!(buys, allorders)
        shuffle!(allorders)
        _doall!(s, allorders, date)
    end
    _lastupdate!(s, date)
end

@doc "Iterates over all pending orders checking for new fills.

$(TYPEDSIGNATURES)

Should be called only once, precisely at the beginning of the main `ping!` function.
Orders are evaluated sequentially, first sell orders than buy orders.

For a randomized evaluation sequence use `UpdateOrdersShuffled` by setting
the value `:sim_update_mode` in the strategy config:
```julia
s.attrs[:sim_update_mode] = UpdateOrdersShuffled()
```
"
function update!(s::Strategy{Sim}, date, ::UpdateOrders)
    _check_update_date(s, date)
    positions!(s, date)
    for (ai, ords) in s.sellorders
        @ifdebug prev_sell_price = 0.0
        for (pt, o) in collect(ords) # Prefetch the orders since `order!` can unqueue
            @deassert prev_sell_price <= pt.price
            # Need to check again if it is queued in case of liquidation events
            isqueued(o, s, ai) || continue
            order!(s, o, date, ai)
            @ifdebug prev_sell_price = pt.price
        end
    end
    for (ai, ords) in s.buyorders
        @ifdebug prev_buy_price = Inf
        for (pt, o) in collect(ords) # Prefetch the orders since `order!` can unqueue
            @deassert prev_buy_price >= pt.price
            # Need to check again if it is queued in case of liquidation events
            isqueued(o, s, ai) || continue
            order!(s, o, date, ai)
            @ifdebug prev_buy_price = pt.price
        end
    end
    _lastupdate!(s, date)
end
