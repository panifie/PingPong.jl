using Misc: MarginMode, WithMargin, Long, Short, PositionSide, ExecAction
import Misc: opposite, reset!
using Instruments.Derivatives: Derivative
using Exchanges: LeverageTier, LeverageTiersDict, leverage_tiers
import Exchanges: maxleverage, tier
using Lang: @ifdebug
using Base: negate
import OrderTypes: isshort, islong

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
@kwdef struct Position{P<:PositionSide,E<:ExchangeID,M<:MarginMode}
    status::Vector{PositionStatus} = [PositionClose()]
    asset::Derivative
    timestamp::Vector{DateTime} = [DateTime(0)]
    liquidation_price::OneVec = [0.0]
    entryprice::OneVec = [0.0]
    maintenance_margin::OneVec = [0.0]
    initial_margin::OneVec = [0.0]
    additional_margin::OneVec = [0.0]
    notional::OneVec = [0.0]
    cash::CCash{E}{S1} where {S1}
    cash_committed::CCash{E}{S2} where {S2}
    leverage::OneVec = [1.0]
    min_size::T where {T<:Real}
    hedged::Bool = false
    tiers::Vector{LeverageTiersDict}
    this_tier::Vector{LeverageTier}
end

function Position{P,E,M}(
    args...; kwargs...
) where {P<:PositionSide,E<:ExchangeID,M<:MarginMode}
    M == NoMargin && error("Trying to construct a position in `NoMargin` mode")
    Position{P,E,M}(args...; kwargs...)
end

@doc """Resets position to initial state.

!!! warning "Also resets leverage"
    When reopening a position, leverage should be set again.
"""
reset!(po::Position, ::Val{:full}) = begin
    po.status[] = PositionClose()
    po.timestamp[] = DateTime(0)
    po.notional[] = 0.0
    leverage!(po, 1.0)
    tier!(po)
    po.liquidation_price[] = 0.0
    entryprice!(po, 0.0)
    maintenance!(po, 0.0)
    margin!(po)
    additional!(po)
    cash!(cash(po), 0.0)
    cash!(committed(po), 0.0)
end

@doc """ Resets the bare fields to close a position.
"""
reset!(po::Position) = begin
    po.status[] = PositionClose()
    po.notional[] = 0.0
    po.liquidation_price[] = 0.0
    entryprice!(po, 0.0)
    maintenance!(po, 0.0)
    margin!(po)
    additional!(po)
    cash!(cash(po), 0.0)
    cash!(committed(po), 0.0)
end

const LongPosition{E<:ExchangeID,M<:WithMargin} = Position{Long,E,M}
const ShortPosition{E<:ExchangeID,M<:WithMargin} = Position{Short,E,M}

@doc "The number of digits to keep for margin calculations."
const POSITION_PRECISION = 4
@doc "The number of digits allowed for leverage values."
const LEVERAGE_PRECISION = 1
const POSITION_ROUNDING_MODE = RoundToZero

@doc "Round function for values of position fields."
function _roundpos(v, digits=POSITION_PRECISION)
    round(v, POSITION_ROUNDING_MODE; digits)
end

_roundlev(po, lev) = _roundpos(clamp(lev, 1.0, maxleverage(po)), LEVERAGE_PRECISION)

@doc "Updates position leverage."
function leverage!(po::Position, v)
    @deassert maxleverage(po) == maxleverage(po, notional(po))
    po.leverage[] = _roundlev(po, v)
end

maxleverage(po::Position, size::Real) = tier(po, size)[2].max_leverage
maxleverage(po::Position) = po.this_tier[].max_leverage

_status!(po::Position, ::PositionClose) = begin
    @assert po.status[] == PositionOpen()
    po.status[] = PositionClose()
end

_status!(po::Position, ::PositionOpen) = begin
    @assert po.status[] == PositionClose()
    po.status[] = PositionOpen()
end

isopen(po::Position) = po.status[] == PositionOpen()
islong(::Position{Long}) = true
islong(::Position{Short}) = false
islong(::Union{Type{Long},Long}) = true
islong(::Union{Type{Short},Short}) = false
isshort(::Position{Short}) = true
isshort(::Position{Long}) = false
isshort(::Union{Type{Short},Short}) = true
isshort(::Union{Type{Long},Long}) = false
function tier(po::Position, size)
    # tier should work with abs values
    @deassert tier(po.tiers[], po.cash.value) == tier(po.tiers[], negate(po.cash.value))
    tier(po.tiers[], size)
end
posside(::Position{P}) where {P<:PositionSide} = P
posside(::Long) = Long()
posside(::Short) = Short()

@doc "Position entryprice."
price(po::Position) = po.entryprice[]
entryprice(po::Position) = price(po)
@doc "Position liquidation price."
liqprice(pos::Position) = pos.liquidation_price[]
@doc "Position leverage."
leverage(pos::Position) = pos.leverage[]
@doc "Position status (open or closed)."
status(pos::Position) = pos.status[]
@doc "Position maintenance margin."
maintenance(pos::Position) = pos.maintenance_margin[]
@doc "Position initial margin (includes additional)."
margin(pos::Position) = pos.initial_margin[]
@doc "Position additional margin."
additional(pos::Position) = pos.additional_margin[]
@doc "Position maintenance margin rate."
mmr(pos::Position) = pos.this_tier[].mmr
@doc "Position notional value."
notional(pos::Position) = pos.notional[]
@doc "Held position."
cash(po::Position) = po.cash
@doc "Position locked in pending orders."
committed(po::Position) = po.cash_committed

@doc "The price where the position is fully liquidated."
function bankruptcy(price::Real, lev::Real)
    @deassert lev != 0.0
    price * (lev - 1.0) / lev
end
function bankruptcy(pos::Position, price)
    lev = leverage(pos)
    bankruptcy(price, lev)
end
function bankruptcy(pos::Position, o::Order{T,A,E,P}) where {T,A,E,P<:PositionSide}
    bankruptcy(pos, o.price)
end

function timestamp!(po::Position, d::DateTime)
    @deassert po.timestamp[] <= d "Position dates can only go forward.($(po.timestamp[]), $d)"
    po.timestamp[] = d
end

@doc "Updates position leverage tier according to size."
function tier!(po::Position, size=notional(po))
    po.this_tier[] = tier(po, size)[2]
end

@doc "Update the entry price."
function entryprice!(po::Position, v=abs(notional(po) / cash(po)))
    po.entryprice[] = v
end

@doc "Update the notional value."
function notional!(po::Position, v)
    @ifdebug v < 0.0 && @warn "Notional value should never be negative ($v)"
    po.notional[] = abs(v)
    # update leverage tier after notional update
    tier!(po)
    v
end

@doc "Sets initial margin given notional and leverage values."
function margin!(po::Position; ntl=notional(po), lev=leverage(po))
    m = _roundpos(ntl / lev)
    @deassert m <= notional(po)
    po.initial_margin[] = m + additional(po)
end

@doc "Sets additional margin (should always be positive)."
function additional!(po::Position, v=0.0)
    @deassert v + margin(po) <= notional(po)
    po.additional_margin[] = abs(v)
end

@doc "Adds margin to a position."
function addmargin!(po::Position, v)
    @deassert margin(po) + v <= notional(po)
    po.additional_margin[] = max(0.0, v + additional(po))
end

@doc "Sets maintenance margin."
function maintenance!(po::Position, v)
    po.maintenance_margin[] = _roundpos(v)
    @deassert maintenance(po) <= margin(po)
    v
end

@doc "Set position cash value."
cash!(po::Position, v) = cash!(cash(po), v)
@doc "Set position committed cash value."
commit!(po::Position, v) = cash!(committed(po), v)

@doc "Calc PNL for long position given `current_price` as input."
function pnl(po::Position{Long}, current_price, amount=cash(po))
    isopen(po) || return 0.0
    (current_price - price(po)) * abs(amount)
end

@doc "Calc PNL for short position given `current_price` as input."
function pnl(po::Position{Short}, current_price, amount=cash(po))
    isopen(po) || return 0.0
    (price(po) - current_price) * abs(amount)
end

@doc "Calc PNL percentage."
pnlpct(po::Position, v) = begin
    isopen(po) || return 0.0
    pnl(po, v, 1.0) / price(po)
end

function pnl(entryprice::T, current_price::T, amount, ::Long) where {T}
    (current_price - entryprice) * abs(amount)
end

function pnl(entryprice::T, current_price::T, amount, ::Short) where {T}
    (entryprice - current_price) * abs(amount)
end

@doc "Sets the liquidation price for a long position."
function liqprice!(po::Position{Long}, v)
    @deassert v <= price(po)
    po.liquidation_price[] = v
end

@doc "Sets the liquidation price for a short position."
function liqprice!(po::Position{Short}, v)
    @deassert v >= price(po) (v, price(po))
    po.liquidation_price[] = v
end

function Base.show(io::IO, po::Position)
    write(io, "Position($(posside(po)), $(po.asset))\n")
    write(io, "entryprice: ")
    write(io, string(price(po)))
    write(io, "\namount: ")
    write(io, string(cash(po)))
    write(io, "\nnotional: ")
    write(io, string(notional(po)))
    write(io, "\nmargin: ")
    write(io, string(margin(po)))
    write(io, "\nleverage: ")
    write(io, string(leverage(po)))
    write(io, "\nmaintenance: ")
    write(io, string(maintenance(po)))
    write(io, "\nliquidation price: ")
    write(io, string(liqprice(po)))
    write(io, "\ndate: ")
    write(io, string(po.timestamp[]))
end

export notional, additional, price, notional!, bankruptcy, pnl
export timestamp!, leverage!, tier!, liqprice!, margin!, maintenance!
export PositionOpen, PositionClose, PositionUpdate, PositionStatus, PositionChange
