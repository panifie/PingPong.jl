using Base: negate
using Executors.Checks: cost, withfees, checkprice
using Executors.Instances
using Executors.Instruments
using Strategies:
    lowat, highat, closeat, openat, volumeat, IsolatedStrategy, NoMarginStrategy
using .Instances: NoMarginInstance
using OrderTypes: LongBuyOrder, LongSellOrder, ShortBuyOrder, ShortSellOrder
using OrderTypes: OrderTypes as ot

include("orders/slippage.jl")

function liqprice1(s::MarginStrategy{Sim}, ai::AssetInstance, size, price, ::LongOrder)
    collateral = size / leverage(ai, Long)
    (collateral - size * price) / (size * (mmr - position_side))
end

@doc "Check that we have enough cash in the strategy currency for buying."
function iscashenough(s::NoMarginStrategy, _, size, ::LongBuyOrder)
    s.cash >= size
end
@doc "Check that we have enough asset hodlings that we want to sell (same with margin)."
function iscashenough(_::Strategy, ai, actual_amount, ::LongSellOrder)
    ai.cash >= actual_amount
end
@doc "A long buy adds to the long position by buying more contracts in QC. Check that we have enough QC."
function iscashenough(s::IsolatedStrategy, ai, size, ::LongBuyOrder)
    s.cash / leverage(ai, Long) >= size
end
@doc "A short sell increases our position in the opposite direction, it spends QC to cover the short. Check that we have enough QC."
function iscashenough(s::IsolatedStrategy, ai, size, ::ShortSellOrder)
    s.cash / leverage(ai, Short) >= size
end
@doc "A short buy reduces the required capital by the leverage. But we shouldn't buy back more than what we have shorted."
function iscashenough(_::IsolatedStrategy, ai, actual_amount, ::ShortBuyOrder)
    ai.cash >= actual_amount
end

function maketrade(
    s::Strategy{Sim}, o::IncreaseOrder, ai; date, actual_price, actual_amount
)
    checkprice(s, ai, actual_price, o)
    net_cost = cost(actual_price, actual_amount)
    size = withfees(net_cost, maxfees(ai), o)
    iscashenough(s, ai, size, o) || return nothing
    Trade(o, date, actual_amount, actual_price, size)
end

function maketrade(s::Strategy{Sim}, o::ReduceOrder, ai; date, actual_price, actual_amount)
    @deassert actual_amount >= 0
    checkprice(s, ai, actual_price, o)
    iscashenough(s, ai, actual_amount, o) || return nothing
    net_cost = cost(actual_price, actual_amount)
    size = withfees(net_cost, maxfees(ai), o)
    Trade(o, date, actual_amount, actual_price, size)
end

@ifdebug begin
    const CTR = Ref(0)
    const cash_tracking = Float64[]
    _vv(v) = v isa Vector ? v[] : v
    function _showcash(s, ai)
        @show s.cash s.cash_committed ai.cash ai.cash_committed
    end
    function _showorder(o)
        display(("comm: ", _vv(o.attrs.committed)))
        display(("fill: ", _vv(o.attrs.unfilled)))
    end
end

@doc "Fills an order with a new trade w.r.t the strategy instance."
function trade!(s::Strategy{Sim}, o, ai; date, price, actual_amount)
    actual_price = with_slippage(s, o, ai; date, price, actual_amount)
    trade = maketrade(s, o, ai; date, actual_price, actual_amount)
    isnothing(trade) && return nothing
    @deassert trade.size != 0.0 "Trade must not be empty, size was $(trade.size)."
    @ifdebug begin
        _showcash(s, ai)
        _showorder(o)
        push!(cash_tracking, s.cash)
        CTR[] += 1
    end
    # record trade
    fill!(o, trade)
    push!(ai.history, trade)
    push!(attr(o, :trades), trade)
    # finalize order if complete
    fullfill!(s, ai, o, trade)
    # updated cash
    cash!(s, ai, trade)
    @ifdebug begin
        _showorder(o)
        _showcash(s, ai)
        println("\n")
    end
    return trade
end
