import Executors: aftertrade!

@doc "Cancel an order in PaperMode with given error."
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

function create_paper_market_order(s, t, ai; amount, date, price, kwargs...)
    volumecap!(s, ai; amount) || return nothing
    obside = orderbook_side(ai, t)
    isempty(obside) && return nothing
    if isnan(price)
        price = first(obside)[1]
    end
    o = create_sim_market_order(s, t, ai; amount, date, price, kwargs...)
    o, obside
end

function SimMode.marketorder!(s::PaperStrategy, o, ai; date, obside)
    _, _, trade = from_orderbook(obside, s, ai, o; o.amount, date)
    if isnothing(trade)
        cancel!(s, o, ai; err=OrderCancelled(o))
        nothing
    else
        hold!(s, ai, o)
        trade
    end
end

function aftertrade!(s::PaperStrategy, ai::A, o::O, t::Trade) where {A,O}
    @info "($(t.date), $(nameof(s))) $(nameof(ordertype(t))) $(nameof(orderside(t))) $(t.amount) of $(t.order.asset) at $(t.price)($(t.size) $(ai.asset.qc))"
    invoke(aftertrade!, Tuple{Strategy,A,O}, s, ai, o)
    position!(s, ai, t)
end
