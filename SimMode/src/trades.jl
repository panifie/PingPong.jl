using Base: negate
using Executors: @amount!, @price!
using Executors.Checks: cost, withfees, checkprice
using Executors.Instances
using Executors.Instruments
using Executors.Instances: NoMarginInstance, Instances as inst
using Strategies: lowat, highat, closeat, openat, volumeat
using Strategies: IsolatedStrategy, NoMarginStrategy
using OrderTypes: BuyOrder, SellOrder, ShortBuyOrder, ShortSellOrder
using OrderTypes: OrderTypes as ot, PositionSide

include("orders/slippage.jl")

@doc "Check that we have enough cash in the strategy currency for buying."
function iscashenough(s::NoMarginStrategy, _, size, o::BuyOrder)
    @deassert committed(o) >= 0.0
    st.freecash(s) + committed(o)  >= size
end
@doc "Check that we have enough asset hodlings that we want to sell."
function iscashenough(_::Strategy, ai, actual_amount, o::SellOrder)
    @deassert cash(ai, Long()) >= 0.0
    @deassert committed(o) >= 0.0
    inst.freecash(ai, Long()) + committed(o) >= actual_amount
end
@doc "A long buy adds to the long position by buying more contracts in QC. Check that we have enough QC."
function iscashenough(s::IsolatedStrategy, ai, size, o::BuyOrder)
    @deassert s.cash >= 0.0
    @deassert committed(o) >= 0.0
    (st.freecash(s) + committed(o)) * leverage(ai, Long()) >= size
end
@doc "A short sell increases our position in the opposite direction, it spends QC to cover the short. Check that we have enough QC."
function iscashenough(s::IsolatedStrategy, ai, size, o::ShortSellOrder)
    @deassert s.cash >= 0.0
    @deassert committed(o) >= 0.0
    (st.freecash(s) + committed(o)) * leverage(ai, Short()) >= size
end
@doc "A short buy reduces the required capital by the leverage. But we shouldn't buy back more than what we have shorted."
function iscashenough(_::IsolatedStrategy, ai, actual_amount, o::ShortBuyOrder)
    @deassert cash(ai, Short()) <= 0.0
    @deassert committed(o) <= 0.0
    @deassert inst.freecash(ai, Short()) <= 0.0
    abs(inst.freecash(ai, Short())) + abs(committed(o)) >= actual_amount
end

function maketrade(
    s::Strategy{Sim}, o::IncreaseOrder, ai; date, actual_price, actual_amount, fees
)
    net_cost = cost(actual_price, actual_amount)
    size = withfees(net_cost, fees, o)
    iscashenough(s, ai, size, o) || return nothing
    @deassert size > 0.0 && net_cost > 0.0
    trade_fees = size - net_cost
    @deassert trade_fees > 0.0 || fees < 0.0
    Trade(
        o;
        date,
        amount=actual_amount,
        price=actual_price,
        fees=trade_fees,
        size,
        lev=leverage(ai, orderpos(o)()),
    )
end

function maketrade(
    s::Strategy{Sim}, o::ReduceOrder, ai; date, actual_price, actual_amount, fees
)
    @deassert actual_amount >= 0
    iscashenough(s, ai, actual_amount, o) || return nothing
    net_cost = cost(actual_price, actual_amount)
    size = withfees(net_cost, fees, o)
    @deassert size > 0.0 && net_cost > 0.0
    trade_fees = net_cost - size
    @deassert trade_fees > 0.0 || fees < 0.0
    Trade(
        o;
        date,
        amount=actual_amount,
        price=actual_price,
        fees=trade_fees,
        size,
        lev=leverage(ai, orderpos(o)()),
    )
end

@doc "Fills an order with a new trade w.r.t the strategy instance."
function trade!(s::Strategy{Sim}, o, ai; date, price, actual_amount, fees=maxfees(ai))
    @ifdebug _afterorder()
    @amount! ai actual_amount
    actual_price = with_slippage(s, o, ai; date, price, actual_amount)
    @price! ai actual_price
    trade = maketrade(s, o, ai; date, actual_price, actual_amount, fees)
    isnothing(trade) && return nothing
    @ifdebug _check_committments(s, ai, trade)
    @ifdebug _beforetrade(s, ai, o, trade, actual_price)
    # record trade
    fill!(ai, o, trade)
    push!(ai.history, trade)
    push!(attr(o, :trades), trade)
    # finalize order if complete
    fullfill!(s, ai, o, trade)
    # update cash
    cash!(s, ai, trade)
    @ifdebug _aftertrade(s, ai, o)
    @ifdebug _check_committments(s)
    @ifdebug  _check_committments(s, ai, trade)
    return trade
end
