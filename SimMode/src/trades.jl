using Base: negate
using Executors.Checks: cost, withfees
using Executors.Instances
using Executors.Instruments
using Strategies: lowat, highat


tradesize(::BuyOrder, ai, cost) = muladd(cost, maxfees(ai), cost)
tradesize(::SellOrder, ai, cost) = muladd(negate(cost), maxfees(ai), cost)

function maketrade(s::Strategy, o::BuyOrder, ai; date, actual_price, actual_amount)
    size = tradesize(o, ai, cost(actual_price, actual_amount))
    # check that we have enough global cash
    size > s.cash && return nothing
    Trade(o, date, actual_amount, size)
end

function maketrade(::Strategy, o::SellOrder, ai; date, actual_price, actual_amount)
    # check that we have enough asset cash
    actual_amount > ai.cash && return nothing
    size = tradesize(o, ai, cost(actual_price, actual_amount))
    Trade(o, date, actual_amount, size)
end

@doc "Fills an order with a new trade w.r.t the strategy instance."
function trade!(s::Strategy, o, ai; date, price, actual_amount)
    actual_price = clamp(price, lowat(ai, date), highat(ai, date))
    trade = maketrade(s, o, ai; date, actual_price, actual_amount)
    isnothing(trade) && return nothing
    # update strategy and asset cash/cash_committed
    cash!(s, ai, trade)
    # record trade
    fill!(o, trade)
    push!(ai.history, trade)
    push!(o.attrs.trades, trade)
    # finalize order if complete
    fullfill!(s, ai, o, trade)
    return trade
end
