using .PaperMode.Instances: _deducted_amount
using Base: negate
using .Executors: attr, committment
import Base: fill!

# NOTE: unfilled is always negative
function fill!(::NoMarginStrategy{Live}, ai::NoMarginInstance, o::BuyOrder, t::BuyTrade)
    @deassert o isa IncreaseOrder && _check_unfillment(o) unfilled(o), typeof(o)
    @deassert committed(o) == o.attrs.committed[] && committed(o) >= 0.0
    # from neg to 0 (buy amount is pos)
    attr(o, :unfilled)[] += t.amount + t.fees_base
    @deassert attr(o, :unfilled)[] |> ltxzero || ltxzero(t.fees_base) (
        o, t.amount, t.fees_base
    )
    # from pos to 0 (buy size is neg)
    attr(o, :committed)[] -= committment(ai, t)
    @deassert gtxzero(ai, committed(o), Val(:price)) || o isa MarketOrder (
        o, committment(ai, t)
    )
end
function fill!(::LiveStrategy, ai::AssetInstance, o::SellOrder, t::SellTrade)
    @deassert o isa SellOrder && _check_unfillment(o)
    @deassert committed(o) == o.attrs.committed[] && committed(o) |> gtxzero
    # from pos to 0 (sell amount is neg)
    amt = _deducted_amount(t)
    attr(o, :unfilled)[] += amt
    @deassert attr(o, :unfilled)[] |> gtxzero
    # from pos to 0 (sell amount is neg)
    attr(o, :committed)[] += amt
    @deassert committed(o) |> gtxzero
end
function fill!(
    ::MarginStrategy{Live}, ai::AssetInstance, o::ShortBuyOrder, t::ShortBuyTrade
)
    @deassert o isa ShortBuyOrder && _check_unfillment(o) o
    @deassert committed(o) == o.attrs.committed[] && committed(o) |> ltxzero
    @deassert attr(o, :unfilled)[] < 0.0
    amt = _deducted_amount(t)
    attr(o, :unfilled)[] += amt # from neg to 0 (buy amount is pos)
    @deassert attr(o, :unfilled)[] |> ltxzero
    # NOTE: committment is always positive except for short buy orders
    # where that's committed is shorted (negative) asset cash
    @deassert t.amount > 0.0 && committed(o) < 0.0
    attr(o, :committed)[] += amt # from neg to 0 (buy amount is pos)
    @deassert committed(o) |> ltxzero
end

@doc "When entering positions, the cash committed from the trade must be downsized by leverage (at the time of the trade)."
function fill!(
    ::MarginStrategy{Live}, ai::MarginInstance, o::IncreaseOrder, t::IncreaseTrade
)
    @deassert o isa IncreaseOrder && _check_unfillment(o) o
    @deassert committed(o) == o.attrs.committed[] && committed(o) > 0.0 t
    attr(o, :unfilled)[] += t.amount
    @deassert attr(o, :unfilled)[] |> ltxzero || o isa ShortSellOrder
    @deassert t.value > 0.0
    attr(o, :committed)[] -= committment(ai, t)
    # Market order spending can exceed the estimated committment
    # ShortSell limit orders can spend more than committed because of slippage
    @deassert committed(o) |> gtxzero || o isa AnyMarketOrder || o isa IncreaseLimitOrder
end

