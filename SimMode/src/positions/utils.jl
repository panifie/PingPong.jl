using OrderTypes.ExchangeTypes: ExchangeID
using OrderTypes: PositionSide, PositionTrade, LiquidationType
using Strategies.Instruments.Derivatives: Derivative
using Executors.Instances: leverage_tiers, tier, position
import Executors.Instances: Position, MarginInstance
using Executors: withtrade!, maintenance!, orders, isliquidatable
using Strategies: IsolatedStrategy, MarginStrategy, exchangeid
using .Instances: PositionOpen, PositionUpdate, PositionClose
using .Instances: margin, maintenance, status, posside
using Misc: DFT

function open_position!(
    s::IsolatedStrategy{Sim}, ai, t::PositionTrade{P}; lev::Option{DFT}=nothing
) where {P<:PositionSide}
    # NOTE: Order of calls is important
    po = position(ai, P)
    lev = isnothing(lev) ? leverage(po) : lev
    @deassert !isopen(po)
    @deassert notional(po) == 0.0
    # Cash should already be updated from trade construction
    @deassert cash(po) == cash(ai, P()) == t.amount
    withtrade!(po, t)
    # Notional should never be above the trade size
    # unless fees are negative
    @deassert notional(po) < t.size || minfees(ai) < 0.0
    # leverage (and margin)
    leverage!(po; lev, price=t.price)
    # finalize
    status!(ai, P(), PositionOpen())
    @deassert status(po) == PositionOpen()
    ping!(s, ai, t, po, PositionOpen())
end

function update_position!(
    s::IsolatedStrategy{Sim}, ai, t::PositionTrade{P}
) where {P<:PositionSide}
    # NOTE: Order of calls is important
    po = position(ai, P)
    @deassert notional(po) != 0.0
    # Cash should already be updated from trade construction
    @deassert cash(po) != t.amount
    withtrade!(po, t)
    # position is still open
    ping!(s, ai, t, po, PositionUpdate())
end

function close_position!(s::IsolatedStrategy{Sim}, ai, p::PositionSide, date=nothing)
    # when a date is given we should close pending orders and sell remaining cash
    if !isnothing(date)
        for o in values(orders(s, ai, p, Buy))
            cancel!(s, o, ai; err=OrderCancelled(o))
        end
        for o in values(orders(s, ai, p, Sell))
            cancel!(s, o, ai; err=OrderCancelled(o))
        end
        @assert iszero(committed(ai, p)) committed(ai, p)
        price = closeat(ai, date)
        amount = nondust(ai, price, p) # abs(cash(ai, p))
        if amount > 0.0
            o = marketorder(s, ai, amount; type=MarketOrder{liqside(p)}, date, price)
            @assert !isnothing(o) &&
                o.date == date &&
                isapprox(o.amount, amount; atol=ai.precision.amount)
            marketorder!(s, o, ai, amount; date)
        end
    end
    reset!(ai, p)
    @assert !isopen(position(ai, p))
end

function update_margin!(pos::Position, qty::Real)
    p = posside(pos)
    price = entryprice(pos)
    lev = leverage(pos)
    size = notional(pos)
    prev_additional = margin(pos) - size / lev
    @deassert prev_additional >= 0.0 && qty >= 0.0
    additional = prev_additional + qty
    liqp = liqprice(p, price, lev, mmr(pos); additional, size)
    liqprice!(pos, liqp)
    # margin!(pos, )
end

@doc "Updates an isolated position in `Sim` mode from a new trade."
function position!(
    s::IsolatedStrategy{Sim}, ai::MarginInstance, t::PositionTrade{P};
) where {P<:PositionSide}
    @assert exchangeid(s) == exchangeid(t)
    @assert t.order.asset == ai.asset
    pos = position(ai, P)
    if isopen(pos)
        @assert !iszero(cash(pos))
        update_position!(s, ai, t)
    else
        open_position!(s, ai, t)
    end
    liquidations!(s, ai, t.date)
end

@doc "Liquidates a position at a particular date.
`fees`: the fees for liquidating a position (usually higher than trading fees.)"
function liquidate!(
    s::MarginStrategy, ai::MarginInstance, p::PositionSide, date, fees=maxfees(ai) * 2.0
)
    for o in orders(s, ai, p)
        cancel!(s, o, ai; err=LiquidationOverride(o, price, date, p))
    end
    pos = position(ai, p)
    amount = pos.cash.value
    price = liqprice(pos)
    o = marketorder(s, ai, amount; type=LiquidationOrder{liqside(p),typeof(p)}, date, price)
    if isnothing(o) # The position is too small to be tradeable, assume cash is lost
        cash!(ai, 0.0, p)
        cash!(committed(pos), 0.0, p)
    else
        marketorder!(s, o, ai, o.amount; date, fees)
        @assert iszero(unfilled(o)) && isdust(ai, price, p) cash(ai, p)
        @assert !isnothing(o) &&
            o.date == date &&
            isapprox(o.amount, amount; atol=ai.precision.amount)
    end
    close_position!(s, ai, p)
end

@doc "Checks asset positions for liquidations and executes them (Non hedged mode, so only the currently open position)."
function liquidations!(s::IsolatedStrategy{Sim}, ai::MarginInstance, date)
    pos = position(ai)
    @assert !isopen(opposite(ai, pos))
    isnothing(pos) && return nothing
    p = posside(pos)()
    if isliquidatable(ai, p, date)
        liquidate!(s, ai, p, date)
    end
end
