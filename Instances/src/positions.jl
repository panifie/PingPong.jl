using Misc: MarginMode, WithMargin, Long, Short, PositionSide, ExecAction
import Misc: opposite, reset!
using Instruments.Derivatives: Derivative
using Exchanges: LeverageTier, LeverageTiersDict, leverage_tiers
import Exchanges: maxleverage, tier

PositionSide(::Type{Buy}) = Long
PositionSide(::Type{Sell}) = Short
PositionSide(::Order{OrderType{Buy}}) = Long
PositionSide(::Order{OrderType{Sell}}) = Short

const OneVec = Vector{DFT}

struct PositionOpen <: ExecAction end
struct PositionUpdate <: ExecAction end
struct PositionClose <: ExecAction end
const PositionStatus = Union{PositionOpen,PositionClose}
const PositionChange = Union{PositionOpen,PositionUpdate,PositionClose}
opposite(::PositionOpen) = PositionClose()
opposite(::PositionClose) = PositionOpen()

@doc "A position tracks the margin state of an asset instance:
- `timestamp`: last update time of the position (`DateTime`)
- `side`: the side of the position `<:PositionSide` `Long` or `Short`
- `tiers`: sorted dict of all the leverage tiers
- `cash`: it is the `notional` value of the position
For the rest of the fields refer to  [ccxt docs](https://docs.ccxt.com/#/README?id=position-structure)
"
@kwdef struct Position{S<:PositionSide,M<:WithMargin}
    status::Vector{PositionStatus} = [PositionClose()]
    asset::Derivative
    timestamp::Vector{DateTime} = [DateTime(0)]
    liquidation_price::OneVec = [0.0]
    entryprice::OneVec = [0.0]
    maintenance_margin::OneVec = [0.0]
    initial_margin::OneVec = [0.0]
    notional::OneVec = [0.0]
    cash::Cash{S1,DFT} where {S1}
    cash_committed::Cash{S2,DFT} where {S2}
    leverage::OneVec = [1.0]
    min_size::T where {T<:Real}
    hedged::Bool = false
    tiers::Vector{LeverageTiersDict}
    this_tier::Vector{LeverageTier}
end

reset!(po::Position) = begin
    _status!(po, PositionClose())
    po.timestamp[] = DateTime(0)
    notional!(po, 0.0)
    leverage!(po, 1.0)
    tier!(po)
    liquidation!(po, 0.0)
    entryprice!(po, 0.0)
    maintenance!(po)
    margin!(po)
    cash!(po, 0.0)
    commit!(po, 0.0)
end

const LongPosition{M<:WithMargin} = Position{Long,M}
const ShortPosition{M<:WithMargin} = Position{Short,M}

maxleverage(po::Position, size::Real) = maxleverage(po.tiers, size)
maxleverage(po::Position) = po.this_tier[].max_leverage

_status!(po::Position, ::PositionClose) = begin
    @assert po.status[] == PositionOpen()
    po.status[] = PositionClose()
end

_status!(po::Position, ::PositionOpen) = begin
    @assert po.status[] == PositionClose()
    po.status[] = PositionOpen()
end

Base.isopen(po::Position) = po.status[] == PositionOpen()
islong(::Position{<:Long}) = true
isshort(::Position{<:Short}) = true
function tier(po::Position, size)
    # tier should work with abs values
    @deassert tier(po, po.cash)[1] == tier(po, negate(po.cash))[1]
    tier(po.tiers[], size)
end

@doc "Position entryprice."
price(po::Position) = po.entryprice[]
@doc "Position liquidation price."
liquidation(pos::Position) = pos.liquidation_price[]
@doc "Position leverage."
leverage(pos::Position) = pos.leverage[]
@doc "Position status (open or closed)."
status(pos::Position) = pos.status[]
@doc "Position maintenance margin."
maintenance(pos::Position) = pos.maintenance_margin[]
@doc "Position initial margin."
margin(pos::Position) = pos.initial_margin[]
@doc "Position maintenance margin rate."
mmr(pos::Position) = pos.this_tier[].mmr
@doc "Position notional value."
notional(pos::Position) = pos.notional[]
@doc "Held position."
cash(po::Position) = po.cash
@doc "Position locked in pending orders."
committed(po::Position) = po.cash_committed
@doc "The price where the position is fully liquidated."
function bankruptcy(pos::Position, price)
    lev = leverage(pos)
    @deassert lev != 0.0
    price * (lev - 1.0) / lev
end
function bankruptcy(pos::Position, o::Order{T,A,E,P}) where {T,A,E,P<:PositionSide}
    bankruptcy(pos, o.price)
end

@doc "The amounts of digits to keep for margin calculations."
const POSITION_PRECISION = 4
const POSITION_ROUNDING_MODE = RoundToZero

@doc "Round function for values of position fields."
function _roundpos(v)
    round(v, POSITION_ROUNDING_MODE; digits=POSITION_PRECISION)
end

function timestamp!(po::Position, d::DateTime)
    @deassert po.timestamp[] <= d "Position dates can only go forward."
    po.timestamp[] = d
end

_roundlev(po, lev) = _roundpos(clamp(lev, 1.0, maxleverage(po)))
@doc "Updates position leverage."
function leverage!(po::Position, v)
    @deassert maxleverage(po) == maxleverage(po, notional(po))
    po.leverage[] = _roundlev(po, v)
end

@doc "Updates leverage based on position state."
function leverage!(po::Position)
    lev = leverage(po)
    lev = _roundlev(po, lev)
    leverage!(po, lev)
end

@doc "Updates position leverage tier according to size."
function tier!(po::Position, size=notional(po))
    po.this_tier[] = tier(po, size)[2]
end

@doc "Updated the entry price.."
function entryprice!(po::Position, v=notional(po) / cash(po))
    po.entryprice[] = v
end

@doc "Updated the entry price given a new notional."
function ntlprice!(po::Position, ntl)
    po.entryprice[] = ntl / cash(po)
    notional!(po, ntl)
end

function margin!(po::Position; ntl=notional(po), lev=leverage(po))
    m = _roundpos(ntl / lev)
    @deassert m <= cash(po)
    po.initial_margin[] = m
end

@doc "Updates maintenance margin."
function maintenance!(po::Position; ntl=notional(po))
    @deassert mmr(po) == tier(po, ntl)[2].mmr
    mm = _roundpos(ntl / mmr(po))
    po.maintenance_margin[] = mm
    @deassert mm <= margin(po)
    mm
end

@doc "The sign for pnl calc is negative for longs."
Base.sign(::Position{Long}) = -1.0
@doc "The sign for pnl calc is positive for shorts."
Base.sign(::Position{Short}) = 1.0

@doc "Calc PNL for position given `current_price` as input."
function pnl(po::Position, current_price)
    !isopen(po) && return 0.0
    (1.0 / price(po) - 1.0 / current_price) * (cash(po) * sign(po))
end

function liquidation!(po::Position{Long}, v)
    @deassert v <= price(po)
    po.liquidation_price[] = v
end

function liquidation!(po::Position{Short}, v)
    @deassert v >= price(po)
    po.liquidation_price[] = v
end

@doc "Udpates notional value."
function notional!(po::Position, size)
    @deassert size <= price(po) * cash(po)
    po.notional[] = size
    tier!(po, size)
    leverage!(po)
end

export notional, price, notional!, ntlprice!, entryprice!
export timestamp!, leverage!, tier!, liquidation!, margin!, maintenance!
export PositionOpen, PositionClose, PositionUpdate, PositionStatus, PositionChange
