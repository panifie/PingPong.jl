using Base: negate
using Executors: @amount!, @price!, aftertrade!, NewTrade
using Executors.Checks: cost, withfees, checkprice
using Executors.Instances
using Executors.Instruments
using Executors.Instances: NoMarginInstance, Instances as inst, price
using Strategies: lowat, highat, closeat, openat, volumeat
using Strategies: IsolatedStrategy, NoMarginStrategy
using OrderTypes: BuyOrder, SellOrder, ShortBuyOrder, ShortSellOrder
using OrderTypes: OrderTypes as ot, PositionSide

include("orders/slippage.jl")

@doc "Check that we have enough cash in the strategy currency for buying."
function iscashenough(s::NoMarginStrategy, _, size, o::BuyOrder)
    @deassert committed(o) |> gtxzero
    st.freecash(s) + committed(o) >= size
end
@doc "Check that we have enough asset hodlings that we want to sell."
function iscashenough(_::Strategy, ai, actual_amount, o::SellOrder)
    @deassert cash(ai, Long()) |> gtxzero
    @deassert committed(o) |> gtxzero
    inst.freecash(ai, Long()) + committed(o) >= actual_amount
end
@doc "A long buy adds to the long position by buying more contracts in QC. Check that we have enough QC."
function iscashenough(s::IsolatedStrategy, ai, size, o::BuyOrder)
    @deassert s.cash |> gtxzero
    @deassert committed(o) |> gtxzero
    (st.freecash(s) + committed(o)) * leverage(ai, Long()) >= size
end
@doc "A short sell increases our position in the opposite direction, it spends QC to cover the short. Check that we have enough QC."
function iscashenough(s::IsolatedStrategy, ai, size, o::ShortSellOrder)
    @deassert s.cash |> gtxzero
    @deassert committed(o) |> gtxzero
    (st.freecash(s) + committed(o)) * leverage(ai, Short()) >= size
end
@doc "A short buy reduces the required capital by the leverage. But we shouldn't buy back more than what we have shorted."
function iscashenough(s::IsolatedStrategy, ai, actual_amount, o::ShortBuyOrder)
    @deassert cash(ai, Short()) |> ltxzero
    @deassert committed(o) |> ltxzero
    @deassert inst.freecash(ai, Short()) |> ltxzero
    abs(inst.freecash(ai, Short())) + abs(committed(o)) >= actual_amount
end

macro maketrade()
    expr = quote
        Trade(
            o;
            date,
            amount=actual_amount,
            price=actual_price,
            fees=fees_quote,
            fees_base,
            size,
            lev=leverage(ai, o),
            entryprice=price(ai, actual_price, o),
        )
    end
    esc(expr)
end

function maketrade(
    s::Strategy{<:Union{Sim,Paper}},
    o::IncreaseOrder,
    ai;
    date,
    actual_price,
    actual_amount,
    fees,
)
    net_cost = cost(actual_price, actual_amount)
    size = withfees(net_cost, fees, o)
    iscashenough(s, ai, size, o) || return nothing
    @deassert size > 0.0 && net_cost > 0.0
    fees_quote = size - net_cost
    fees_base = ZERO
    @deassert fees_quote > 0.0 || fees < 0.0
    @maketrade
end

function maketrade(
    s::Strategy{<:Union{Sim,Paper}},
    o::ReduceOrder,
    ai;
    date,
    actual_price,
    actual_amount,
    fees,
)
    @deassert actual_amount >= 0
    iscashenough(s, ai, actual_amount, o) || return nothing
    net_cost = cost(actual_price, actual_amount)
    size = withfees(net_cost, fees, o)
    @deassert size > 0.0 && net_cost > 0.0
    fees_quote = net_cost - size
    fees_base = ZERO
    @deassert fees_quote > 0.0 || fees < 0.0
    @maketrade
end

@doc "Fills an order with a new trade w.r.t the strategy instance."
function trade!(
    s::Strategy,
    o,
    ai;
    date,
    price,
    actual_amount,
    fees=maxfees(ai),
    slippage=true,
    kwargs...,
)
    @deassert abs(committed(o)) > 0.0
    @ifdebug _afterorder()
    @amount! ai actual_amount
    actual_price = slippage ? with_slippage(s, o, ai; date, price, actual_amount) : price
    @price! ai actual_price
    trade = maketrade(s, o, ai; date, actual_price, actual_amount, fees, kwargs...)
    isnothing(trade) && begin
        # unqueue or decommit order if filled
        aftertrade!(s, ai, o)
        return nothing
    end
    @ifdebug _beforetrade(s, ai, o, trade, actual_price)
    # record trade
    @deassert !isdust(ai, o) committed(o), o
    fill!(s, ai, o, trade)
    push!(ai.history, trade)
    push!(trades(o), trade)
    # update cash
    cash!(s, ai, trade)
    # unqueue or decommit order if filled
    aftertrade!(s, ai, o, trade)
    ping!(s, ai, trade, NewTrade())
    @ifdebug _aftertrade(s, ai, o)
    @ifdebug _check_committments(s, ai)
    @ifdebug _check_committments(s, ai, trade)
    return trade
end

ping!(::Strategy, ai, trade, ::NewTrade) = nothing
