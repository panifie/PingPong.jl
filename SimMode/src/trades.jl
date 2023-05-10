using Base: negate
using Executors.Checks: cost, withfees, checkprice
using Executors.Instances
using Executors.Instruments
using Strategies: lowat, highat, closeat, openat, volumeat
using Strategies: IsolatedStrategy, NoMarginStrategy
using Executors.Instances: NoMarginInstance
using OrderTypes: BuyOrder, SellOrder, ShortBuyOrder, ShortSellOrder
using OrderTypes: OrderTypes as ot, PositionSide

include("orders/slippage.jl")

@doc "Check that we have enough cash in the strategy currency for buying."
function iscashenough(s::NoMarginStrategy, _, size, ::BuyOrder)
    s.cash >= size
end
@doc "Check that we have enough asset hodlings that we want to sell (same with margin)."
function iscashenough(_::Strategy, ai, actual_amount, o::SellOrder)
    cash(ai, Long()) >= actual_amount
end
@doc "A long buy adds to the long position by buying more contracts in QC. Check that we have enough QC."
function iscashenough(s::IsolatedStrategy, ai, size, ::BuyOrder)
    s.cash / leverage(ai, Long()) >= size
end
@doc "A short sell increases our position in the opposite direction, it spends QC to cover the short. Check that we have enough QC."
function iscashenough(s::IsolatedStrategy, ai, size, ::ShortSellOrder)
    s.cash / leverage(ai, Short()) >= size
end
@doc "A short buy reduces the required capital by the leverage. But we shouldn't buy back more than what we have shorted."
function iscashenough(_::IsolatedStrategy, ai, actual_amount, ::ShortBuyOrder)
    cash(ai, Short()) >= actual_amount
end

function maketrade(
    s::Strategy{Sim}, o::IncreaseOrder, ai; date, actual_price, actual_amount, fees
)
    net_cost = cost(actual_price, actual_amount)
    size = withfees(net_cost, fees, o)
    iscashenough(s, ai, size, o) || return nothing
    Trade(o, date, actual_amount, actual_price, size)
end

function maketrade(
    s::Strategy{Sim}, o::ReduceOrder, ai; date, actual_price, actual_amount, fees
)
    @deassert actual_amount >= 0
    iscashenough(s, ai, actual_amount, o) || return nothing
    net_cost = cost(actual_price, actual_amount)
    size = withfees(net_cost, fees, o)
    Trade(o, date, actual_amount, actual_price, size)
end

@doc "Fills an order with a new trade w.r.t the strategy instance."
function trade!(s::Strategy{Sim}, o, ai; date, price, actual_amount, fees=maxfees(ai))
    @ifdebug _afterorder()
    actual_price = with_slippage(s, o, ai; date, price, actual_amount)
    trade = maketrade(s, o, ai; date, actual_price, actual_amount, fees)
    isnothing(trade) && return nothing
    @ifdebug _check_committments(s, ai)
    @ifdebug _beforetrade(s, ai, o, trade, actual_price)
    # record trade
    fill!(o, trade)
    push!(ai.history, trade)
    push!(attr(o, :trades), trade)
    # finalize order if complete
    fullfill!(s, ai, o, trade)
    # update cash
    cash!(s, ai, trade)
    @ifdebug _aftertrade(s, ai, o)
    @ifdebug _check_committments(s)
    @ifdebug _check_committments(s, ai)
    return trade
end
