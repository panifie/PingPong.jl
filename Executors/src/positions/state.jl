using OrderTypes: PositionTrade, IncreaseTrade, ReduceTrade, liqside, LiquidationOverride
using Instances: leverage, _roundlev, _roundpos, Position, margin, maintenance, lastprice
import Instances: leverage!, maintenance!, notional!, entryprice!, tier, liqprice
using Executors.Instances: MarginInstance, liqprice!
using Strategies: lowat, highat

@doc "Update the entry price from notional and cash."
function update_price!(po::Position, ntl)
    @deassert notional(po) >= 0.0 && ntl >= 0.0
    po.entryprice[] = abs(ntl / cash(po))
end
@doc "Updates notional value."
function update_notional!(po::Position; ntl)
    # NOTE: Order is important
    ntl = abs(ntl)
    po.notional[] = ntl
    tier!(po, ntl)
    update_price!(po, ntl)
    update_leverage!(po; lev=leverage(po))
end

_inv(::Long, leverage, mmr) = 1.0 - 1.0 / leverage + mmr
_inv(::Short, leverage, mmr) = 1.0 + 1.0 / leverage - mmr

function liqprice(p::PositionSide, entryprice, leverage, mmr; additional=0.0, notional=1.0)
    inv = _inv(p, leverage, mmr)
    add = additional / notional # == amount * entryprice
    muladd(entryprice, inv, add) |> _roundpos
end

@doc "Updates leverage based on position state."
function update_leverage!(po::Position{P}; lev, price=price(po), mmr=mmr(po)) where {P}
    lev = leverage!(po, lev)
    # new liquidation price from updated leverage
    let ntl = notional(po)
        if iszero(ntl)
            liqprice!(po, 0.0)
        else
            liqprice!(
                po,
                liqprice(
                    P(), price, lev, mmr; additional=additional(po), notional=notional(po)
                ),
            )
        end
    end
    # update margin from new leverage
    margin!(po)
    update_maintenance!(po)
end

@doc "Updates maintenance margin."
function update_maintenance!(po::Position; ntl=notional(po))
    @deassert mmr(po) == tier(po, ntl)[2].mmr
    mm = ntl * mmr(po)
    maintenance!(po, mm)
end

@doc "Update position price, notional and cash from a new trade."
function withtrade!(po::Position{P}, t::PositionTrade{P}) where {P}
    # the position cash should already be updated at trade creation
    # so this not-equation should be true since the position is in a stale state
    @deassert iszero(price(po)) ||
        abs(notional(po) / cash(po)) != price(po) ||
        abs(cash(po)) == abs(t.order.amount) - abs(t.amount)
    timestamp!(po, t.date)
    # @show cash(po) t.amount positionside(t) orderside(t)
    ntl = _roundpos(cash(po) * t.price)
    # ntl > 1e3 && error()
    @deassert ntl > 0.0 || cash(po) <= 0.0
    # notional updates the price, then leverage, then the liq price.
    update_notional!(po; ntl)
end

using Base: negate
@doc "Some exchanges add funding rates and trading fees to the liquidation price, we use a default buffer of $LIQUIDATION_BUFFER."
const LIQUIDATION_BUFFER =
    parse(DFT, get(ENV, "PINGPONG_LIQUIDATION_BUFFER", "0.02")) |> abs |> negate

_pricebypos(ai, date, ::Long) = lowat(ai, date)
_pricebypos(ai, date, ::Short) = highat(ai, date)
_buffered(price, ::Long) = muladd(price, LIQUIDATION_BUFFER, price)
_buffered(price, ::Short) = muladd(price, abs(LIQUIDATION_BUFFER), price)
_checkbuffered(buffered, price, ::Long) = buffered <= price
_checkbuffered(buffered, price, ::Short) = buffered >= price
_iscrossed(ai, price, ::Long) = price <= Instances.liqprice(ai, Long())
_iscrossed(ai, price, ::Short) = price >= Instances.liqprice(ai, Short())

@doc "Tests if a position should be liquidated at a particular date."
function isliquidatable(
    ::Strategy{Sim}, ai::MarginInstance, p::PositionSide, date::DateTime
)
    let price = _pricebypos(ai, date, p)
        buffered = _buffered(price, p)
        @deassert _checkbuffered(buffered, price, p)
        return _iscrossed(ai, buffered, p)
    end
end

@doc "Tests if a position should be liquidated at a particular price."
function isliquidatable(::Strategy{Paper}, ai::MarginInstance, p::PositionSide, date::DateTime)
    price = lastprice(ai) # pytofloat(ticker!(ai.asset.raw, ai.exchange)["last"])
    _iscrossed(ai, price, p)
end
