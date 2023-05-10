using OrderTypes: PositionTrade, IncreaseTrade, ReduceTrade, liqside, LiquidationOverride
using Instances: leverage, _roundlev, _roundpos, Position
import Instances: leverage!, maintenance!, notional!, entryprice!, tier, liqprice
using Executors.Instances: MarginInstance, liqprice!
using Strategies: lowat

# function hold!(s::IsolatedStrategy, ai::MarginInstance, o::IncreaseOrder)
#     push!(s.holdings, ai)
#     pos = position(ai, o)
# end
# hold!(::IsolatedStrategy, _, ::ReduceOrder) = nothing
#

@doc "Updates notional value."
function notional!(po::Position, size; price)
    @deassert size > 0.0
    @deassert size <= price(po) * cash(po)
    po.notional[] = size
    tier!(po, size)
    entryprice!(po, price)
    leverage!(po; lev=leverage(po), price)
end

_inv(::Long, leverage, mmr) = 1.0 - 1.0 / leverage + mmr
_inv(::Short, leverage, mmr) = 1.0 + 1.0 / leverage - mmr

function liqprice(p::PositionSide, entryprice, leverage, mmr; additional=0.0, size=1.0)
    inv = _inv(p, leverage, mmr)
    add = additional / size # size == amount * entryprice
    muladd(entryprice, inv, add) |> _roundpos
end

@doc "Updates leverage based on position state."
function leverage!(po::Position{P}; lev, price=price(po), mmr=mmr(po)) where {P}
    lev = leverage!(po, lev)
    # new liquidation price from updated leverage
    liqprice!(po, liqprice(P(), price, lev, mmr))
    # update margin from new leverage
    margin!(po)
    maintenance!(po)
end

@doc "Updates maintenance margin."
function maintenance!(po::Position; ntl=notional(po))
    @deassert mmr(po) == tier(po, ntl)[2].mmr
    mm = ntl * mmr(po)
    maintenance!(po, mm)
end

@doc "Update the entry price as the average price of the previous notional and the input notional."
function withnotional!(po::Position, ntl)
    po.entryprice[] = (notional(po) + ntl) / cash(po)
end

# When entering a position the notional comes from price*amount
# and is _added_ to the position so it is positive
_notional(t::IncreaseTrade) = abs(t.price * t.amount)
# When exiting a position fees are already deducted from the trade size
# and is _removed_ from the position so it is negative
_notional(t::ReduceTrade) = negate(abs(t.size))

@doc "Update position price, notional and cash from a new trade."
function withtrade!(po::Position{P}, t::PositionTrade{P}) where {P}
    timestamp!(po, t.date)
    # the position cash should already be updated at trade creation
    # so this equation should not be true since the position is in a stale state
    @deassert notional(po) / cash(po) != price(po)
    ntl = _roundpos(notional(po) + _notional(t))
    # notional updates the price, then leverage, then the liq price.
    notional!(po, ntl; t.price)
end

using Base: negate
@doc "Some exchanges add funding rates and trading fees to the liquidation price, we use a default buffer of $LIQUIDATION_BUFFER."
const LIQUIDATION_BUFFER = negate(0.04)

_pricebypos(ai, date, ::Long) = lowat(ai, date)
_pricebypos(ai, date, ::Short) = highat(ai, date)
_buffered(price, ::Long) = muladd(price, LIQUIDATION_BUFFER, price)
_buffered(price, ::Short) = muladd(price, abs(LIQUIDATION_BUFFER), price)
_checkbuffered(buffered, price, ::Long) = buffered <= price
_checkbuffered(buffered, price, ::Short) = buffered >= price
_iscrossed(ai, price, ::Long) = price <= Instances.liqprice(ai, Long())
_iscrossed(ai, price, ::Short) = price >= Instances.liqprice(ai, Short())

@doc "Tests if a position should be liquidated at a particular date."
function isliquidated(ai::MarginInstance, p::PositionSide, date)
    let price = _pricebypos(ai, date, p)
        buffered = _buffered(price, p)
        @deassert _checkbuffered(buffered, price, p)
        return _iscrossed(ai, buffered, p)
    end
end

@doc "Liquidates a position at a particular date.
`fees`: the fees for liquidating a position (usually higher than trading fees.)"
function liquidate!(
    s::MarginStrategy,
    ai::MarginInstance,
    p::PositionSide,
    date,
    price,
    fees=maxfees(ai) * 2.0,
)
    for o in orders(s, ai, p)
        cancel!(s, o, ai; err=LiquidationOverride(o, price, date, p))
    end
    pos = position(ai, p)
    amount = cash(pos, p)
    o = marketorder(ai, price, amount; type=LiquidationType{liqside(p)}, date)
    @assert iszero(committed(ai, p))
    @assert !isnothing(o) && o.date == date && o.amount == amount
    marketorder!(s, o, ai, amount; date, fees)
    display("state.jl:114")
end
