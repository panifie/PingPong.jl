using Base: negate

cost(price, amount) = price * amount
withfees(cost, fees) = muladd(cost, fees, cost)

# takevol specifies how much of a candle volume should we assume "we can take" to fill our orders
# If our orders exceede this, they should be considered partially filled.
_takevol!(s) = @lget! s.config.attrs :max_take_vol 0.05
_takevol(s) = s.config.attrs[:max_take_vol]
Orders.ordersdefault!(s::Strategy{Sim}) = begin
    @assert 0.0 < _takevol!(s) <= 1.0
end

tradesize(::BuyOrder, ai, cost) = muladd(cost, ai.fees, cost)
tradesize(::SellOrder, ai, cost) = muladd(negate(cost), ai.fees, cost)

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
    fullfill!(s, ai, o)
    return trade
end

@doc "Iterates over all pending orders checking for new fills. Should be called only once, precisely at the beginning of a `ping!` function."
function Executors.pong!(s::Strategy{Sim}, date, ::UpdateOrders)
    for (ai, o) in s.buyorders
        pong!(s, o, date, ai)
    end
    for (ai, o) in s.sellorders
        pong!(s, o, date, ai)
    end
end
