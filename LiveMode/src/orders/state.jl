using .PaperMode.Instances: amount_with_fees
using Base: negate
using .Executors: attr, committment, _check_unfillment, IncreaseLimitOrder, strategycash!
import Base: fill!

# NOTE: unfilled is always negative
function fill!(::NoMarginStrategy{Live}, ai::NoMarginInstance, o::BuyOrder, t::BuyTrade)
    @deassert o isa IncreaseOrder && _check_unfillment(o) unfilled(o), typeof(o)
    @deassert committed(o) == o.attrs.committed[] && committed(o) >= 0.0
    # from neg to 0 (buy amount is pos)
    attr(o, :unfilled)[] += t.amount + t.fees_base
    @deassert ltxzero(ai, attr(o, :unfilled)[], Val(:amount)) ||
        gtxzero(ai, t.fees_base, Val(:amount)) (
        o, attr(o, :unfilled)[], t.amount, t.fees_base
    )
    # from pos to 0 (buy size is neg)
    attr(o, :committed)[] -= committment(ai, t)
    @deassert gtxzero(ai, committed(o), Val(:price)) ||
        o isa MarketOrder ||
        gtxzero(ai, t.fees_base, Val(:amount)) (
        o, committed(o), attr(o, :unfilled)[], committment(ai, t), t.fees_base, t.fees
    )
end
function fill!(::LiveStrategy, ai::AssetInstance, o::SellOrder, t::SellTrade)
    @deassert o isa SellOrder && _check_unfillment(o)
    @deassert committed(o) == o.attrs.committed[] && gtxzero(ai, committed(o), Val(:amount))
    # from pos to 0 (sell amount is neg)
    amt = amount_with_fees(t)
    @ifdebug if o isa AnyMarketOrder
        @info "AMOUNT: " amt attr(o, :unfilled) attr(o, :committed) o.amount
    end
    attr(o, :unfilled)[] += amt
    @deassert gtxzero(ai, attr(o, :unfilled)[], Val(:amount))
    # from pos to 0 (sell amount is neg)
    attr(o, :committed)[] += amt
    @deassert gtxzero(ai, committed(o), Val(:cost)) (
        committed(o), attr(o, :unfilled)[], t.fees, t.fees_base
    )
end
function fill!(
    ::MarginStrategy{Live}, ai::AssetInstance, o::ShortBuyOrder, t::ShortBuyTrade
)
    @deassert o isa ShortBuyOrder && _check_unfillment(o) o
    @deassert committed(o) == o.attrs.committed[] && ltxzero(ai, committed(o), Val(:price))
    @deassert attr(o, :unfilled)[] < 0.0
    amt = amount_with_fees(t)
    attr(o, :unfilled)[] += amt # from neg to 0 (buy amount is pos)
    @deassert ltxzero(ai, attr(o, :unfilled)[], Val(:amount))
    # NOTE: committment is always positive except for short buy orders
    # where that's committed is shorted (negative) asset cash
    @deassert t.amount > 0.0 && committed(o) < 0.0 (committed(o), trades(o))
    attr(o, :committed)[] += amt # from neg to 0 (buy amount is pos)
    @deassert ltxzero(ai, committed(o), Val(:amount))
end

@doc """ Fills an increase order for a margin strategy.

This function fills an increase order for a margin strategy based on a given trade. 
It updates the unfilled and committed attributes of the order according to the trade.

Note:
When entering positions, the cash committed from the trade must be downsized by leverage (at the time of the trade).
"""
function fill!(
    ::MarginStrategy{Live}, ai::MarginInstance, o::IncreaseOrder, t::IncreaseTrade
)
    @deassert o isa IncreaseOrder && _check_unfillment(o) o
    @deassert committed(o) == o.attrs.committed[] && committed(o) > 0.0 t
    attr(o, :unfilled)[] += t.amount
    @deassert ltxzero(ai, attr(o, :unfilled)[], Val(:amount)) || o isa ShortSellOrder
    @deassert t.value > 0.0
    attr(o, :committed)[] -= committment(ai, t)
    # Market order spending can exceed the estimated committment
    # ShortSell limit orders can spend more than committed because of slippage
    @deassert gtxzero(ai, committed(o), Val(:price)) ||
        o isa AnyMarketOrder ||
        o isa IncreaseLimitOrder
end

function Instances.cash!(s::LiveStrategy, ai, t::Trade)
    @debug "trades: cash before" _module = LogWatchTrade cash(s).value cash(ai, posside(t)).value timestamp(ai, posside(t)) t.date
    if timestamp(ai, posside(t)) <= t.date
        @debug "trades: cash updating" _module = LogWatchTrade
        strategycash!(s, ai, t)
        cash!(ai, t)
        @debug "trades: cash after" _module = LogWatchTrade cash(s).value cash(ai, posside(t)).value timestamp(ai, posside(t))
    end
end
