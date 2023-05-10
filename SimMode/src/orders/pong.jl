import Executors: pong!
using Executors
using Executors: iscommittable, priceat, marketorder, hold!
using OrderTypes: LimitOrderType, MarketOrderType
using Lang: @lget!, Option

@doc "Creates a simulated limit order."
function pong!(s::Strategy{Sim}, ai, t::Type{<:Order{<:LimitOrderType}}; amount, kwargs...)
    o = _create_sim_limit_order(s, t, ai; amount, kwargs...)
    isnothing(o) && return nothing
    limitorder_ifprice!(s, o, o.date, ai)
end

@doc "Creates a simulated market order."
function pong!(
    s::NoMarginStrategy{Sim}, ai, t::Type{<:MarketOrder}; amount, date, kwargs...
)
    o = _create_sim_market_order(s, t, ai, Long(); amount, date, kwargs...)
    isnothing(o) && return nothing
    marketorder!(s, o, ai, amount; date, kwargs...)
end

_lastupdate!(s, date) = s.attrs[:sim_last_orders_update] = date
_lastupdate(s) = s.attrs[:sim_last_orders_update]
function _check_update_date(s, date)
    _lastupdate(s) >= date &&
        error("Tried to update orders multiple times on the same date.")
end
using Executors.Instances.DataStructures: SAIterationState
using Simulations.Random: shuffle!

_dopush!(side_orders, all_orders) =
    for (ai, ords) in side_orders
        push!(all_orders, (ai, ords))
    end

_dopong!(s, ai, ai_orders, date) =
    for o in ai_orders
        pong!(s, o, date, ai)
    end

_doall!(s, all_orders, date) =
    for (ai, ords) in all_orders
        _dopong!(s, ai, ords, date)
    end

@doc """Iterates over all pending orders checking for new fills. If you don't have any callbacks attached to orders,
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
function pong!(s::Strategy{Sim}, date, ::UpdateOrdersShuffled)
    _check_update_date(s, date)
    allorders = Tuple{eltype(s.holdings),Union{valtype(s.buyorders),valtype(s.sellorders)}}[]
    _dopush!(s.sellorders, allorders)
    _dopush!(s.buyorders, allorders)
    shuffle!(allorders)
    _doall!(s, allorders, date)
    _lastupdate!(s, date)
end

@doc "Iterates over all pending orders checking for new fills.
Should be called only once, precisely at the beginning of the main `ping!` function.
Orders are evaluated sequentially, first sell orders than buy orders.

For a randomized evaluation sequence use `UpdateOrdersShuffled`.
"
function pong!(s::Strategy{Sim}, date, ::UpdateOrders)
    _check_update_date(s, date)
    for (ai, ords) in s.sellorders
        @ifdebug prev_sell_price = 0.0
        for (pt, o) in ords
            @deassert prev_sell_price <= pt.price
            order!(s, o, date, ai)
            @ifdebug prev_sell_price = pt.price
        end
    end
    for (ai, ords) in s.buyorders
        @ifdebug prev_buy_price = Inf
        for (pt, o) in ords
            @deassert prev_buy_price >= pt.price
            order!(s, o, date, ai)
            @ifdebug prev_buy_price = pt.price
        end
    end
    _lastupdate!(s, date)
end

@doc "Cancel orders for a particular asset instance."
function pong!(
    s::Strategy{Sim}, ai::AssetInstance, ::CancelOrders; t::Type{<:OrderSide}=Both
)
    pop!(s, ai, t)
end
