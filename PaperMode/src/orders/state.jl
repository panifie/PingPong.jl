import .Executors: aftertrade!

@doc """ Cancels an order in PaperMode with a given error.

$(TYPEDSIGNATURES)

The function attempts to cancel the order by invoking the `cancel!` function with the given strategy, order, and asset.
If the order is associated with a task in the `:paper_order_tasks` attribute of the simulation, the task is marked as not alive and removed from the tasks.

"""
function Executors.cancel!(s::Strategy{Paper}, o::Order, ai::T; err::OrderError) where {T}
    try
        invoke(Executors.cancel!, Tuple{Strategy,Order,T}, s, o, ai; err)
    finally
        let tasks = attr(s, :paper_order_tasks)
            order_task = get(tasks, o, nothing)
            isnothing(order_task) || begin
                order_task.alive[] = false
                delete!(tasks, o)
            end
        end
    end
end

@doc """ Creates a paper market order with volume capped to the daily limit.

$(TYPEDSIGNATURES)

The function first checks if the order volume exceeds the daily limit using the `volumecap!` function.
If the volume is within the limit, it fetches the appropriate side of the orderbook using the `orderbook_side` function.
If the price is not provided, it sets the price to the first price in the orderbook.
Finally, it creates a simulated market order using the `create_sim_market_order` function.

"""
function create_paper_market_order(s, t, ai; amount, date, price, kwargs...)
    if volumecap!(s, ai; amount)
    else
        @debug "paper market order: overcapacity" ai = raw(ai) amount liq = _paper_liquidity(
            s, ai
        )
        return nothing
    end
    obside = orderbook_side(ai, t)
    if isempty(obside)
        @debug "paper market order: empty OB" ai = raw(ai) t
        return nothing
    end
    if isnan(price)
        price = first(obside)[1]
    end
    o = create_sim_market_order(s, t, ai; amount, date, price, kwargs...)
    o, obside
end

@doc """ Executes a market order in PaperMode.

$(TYPEDSIGNATURES)

The function executes the order by invoking the `from_orderbook` function with the given strategy, order, asset, and orderbook side.
If the trade is not successful, it cancels the order.
If the trade is successful, it starts tracking the order.

"""
function SimMode.marketorder!(s::PaperStrategy, o, ai; date, obside)
    _, _, trade = from_orderbook(obside, s, ai, o; o.amount, date)
    if isnothing(trade)
        cancel!(s, o, ai; err=OrderCanceled(o))
        nothing
    else
        hold!(s, ai, o)
        trade
    end
end

@doc """ Handles the actions to be taken after a trade in PaperMode.

$(TYPEDSIGNATURES)

The function logs the details of the trade including the date, strategy, order type, order side, amount, asset, price, and size.
It then invokes the `aftertrade!` function with the given strategy, asset, and order.
Finally, it updates the position with the trade.

"""
function aftertrade!(
    s::MarginStrategy{Paper}, ai::A, o::O, t=nothing
) where {A,O<:Union{AnyFOKOrder,AnyIOCOrder,AnyMarketOrder}}
    @info "($(t.date), $(nameof(s))) $(nameof(ordertype(t))) $(nameof(orderside(t))) $(t.amount) of $(t.order.asset) at $(t.price)($(t.size) $(ai.asset.qc))"
    invoke(aftertrade!, Tuple{Strategy,A,<:O,typeof(t)}, s, ai, o, t)
end

function aftertrade!(s::MarginStrategy{Paper}, ai::A, o::O, t=nothing) where {A,O<:AnyLimitOrder}
    invoke(aftertrade!, Tuple{Strategy,A,O,typeof(t)}, s, ai, o, t)
end
