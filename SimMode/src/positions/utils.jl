using OrderTypes.ExchangeTypes: ExchangeID
using OrderTypes: PositionSide, PositionTrade
using Strategies.Instruments.Derivatives: Derivative
using Executors.Instances: leverage_tiers, tier, position
import Executors.Instances: Position, MarginInstance
using Strategies: IsolatedStrategy, MarginStrategy
using .Instances: PositionOpen, PositionUpdate, PositionClose, _roundpos

_inv(::Long, leverage, mmr) = 1.0 - 1.0 / leverage + mmr
_inv(::Short, leverage, mmr) = 1.0 + 1.0 / leverage - mmr

function liqprice(p::PositionSide, entryprice, leverage, mmr; additional=0.0, size=1.0)
    inv = 1.0 - 1.0 / leverage + mmr
    inv = _inv(p, leverage, mmr)
    add = additional / size # size == amount * entryprice
    muladd(entryprice, inv, add) |> _roundpos
end

notionalsize(t::Trade, ::Long) = _roundpos(t.price * t.amount)
notionalsize(t::Trade, ::Short) = _roundpos(negate(t.price * t.amount))
function notionalsize(ai, t::Trade{O,A,E,P} where {O,A,E}) where {P<:PositionSide}
    # Notional should never be above the trade size
    # unless fees are negative
    notional = notionalsize(t, P())
    @deassert notional < t.size || minfees(ai) < 0.0
    @deassert P == Long ? notional > 0.0 : notional < 0.0
    notional
end

function open_position!(
    s::IsolatedStrategy{Sim}, ai, t::PositionTrade{P}; leverage=1.0
) where {P<:PositionSide}
    # NOTE: Order of calls is important
    po = position(ai, P)
    @deassert !isopen(po)
    timestamp!(po, t.date)
    # quantities
    entryprice!(po, t.price)
    @deassert cash(ai, P()) == t.amount
    notional!(po, notionalsize(ai, t))
    # leverage
    tier!(po)
    leverage = leverage!(po, leverage)
    # new liquidation price from trade price as current price and updated leverage
    liquidation!(po, liqprice(P(), t.price, leverage, mmr(po)))
    # update margin from new leverage
    margin!(po)
    maintenance!(po)
    # finalize
    status!(ai, P(), PositionOpen())
    ping!(s, ai, t, po, PositionOpen())
end

function update_position!(
    s::IsolatedStrategy{Sim}, ai, t::PositionTrade{P}
) where {P<:PositionSide}
    # NOTE: Order of calls is important
    po = position(ai, P)
    @deassert notional(po) != 0.0
    timestamp!(po, t.date)
    # quantities
    ntlprice!(po, notional(po) + notionalsize(t, P()))
    # calc margin and liquidation price
    liquidation!(po, liqprice(P(), price(po), leverage(po), mmr(po)))
    margin!(po)
    maintenance!(po)
    # position is still open
    ping!(s, ai, t, po, PositionUpdate())
end
function close_position!(s::IsolatedStrategy{Sim}, ai, t::PositionTrade{P}) where {P}
    reset!(position(ai, P()))
    # status!(ai, P(), PositionClose())
end

function addmargin!(pos::Position, qty::Real)
    pos.liquidation_price[] = _roundpos(pos.liquidation_price[] + pos.cash / qty)
end

function position!(
    s::IsolatedStrategy, ai::MarginInstance, t::PositionTrade{P}
) where {P<:PositionSide}
    pos = position(ai, P)
    if isopen(pos)
        if iszero(cash(pos))
            close_position!(s, ai, t)
        else
            update_position!(s, ai, t)
        end
    else
        open_position!(s, ai, t)
    end
end

function position!(s::IsolatedStrategy{Sim}, t::BuyTrade{<:Derivative}, ai; leverage)
    @assert exchangeid(s) == exchangeid(t)
    @assert t.order.asset == ai.asset
    if !isopen(ai.longpos)
        init_position!(s, t, ai; leverage)
        # timestamp,
        # liquidation_price,
        # entryprice,
        # initial_margin,
        # maintenance_margin,
        # notional,
        # leverage,
        # min_size,
        # tiers,
    end
end
