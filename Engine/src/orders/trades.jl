using Base: negate

cost(price, amount) = price * amount
withfees(cost, fees) = muladd(cost, fees, cost)
spreadopt(::Val{:spread}, date, ai) = sim.spreadat(ai, date, Val(:opcl))
spreadopt(n::T, args...) where {T<:Real} = n
spreadopt(v, args...) = error("`base_slippage` option value not supported ($v)")

function _base_slippage(s::Strategy, date::DateTime, ai)
    spreadopt(s.attrs[:base_slippage], date, ai)
end
Orders.ordersdefault!(s::Strategy{Sim}) = begin
    s.attrs[:base_slippage] = Val(:spread)
end

tradesize(::BuyOrder, ai, cost) = muladd(cost, maxfees(ai), cost)
tradesize(::SellOrder, ai, cost) = muladd(negate(cost), maxfees(ai), cost)

function maketrade(s::Strategy, o::BuyOrder, ai; date, price, amount)
    size = tradesize(o, ai, cost(price, amount))
    # check that we have enough global cash
    size > s.cash && return nothing
    Trade(o, date, amount, size)
end

function maketrade(::Strategy, o::SellOrder, ai; date, price, amount)
    # check that we have enough asset cash
    amount > ai.cash && return nothing
    size = tradesize(o, ai, cost(price, amount))
    Trade(o, date, amount, size)
end

@doc "Fills an order with a new trade w.r.t the strategy instance."
function trade!(s::Strategy, o, ai; date=o.date, price=o.price, amount=o.amount)
    trade = maketrade(s, o, ai; date, price, amount)
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
