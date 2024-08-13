using .Misc: MarginMode, WithMargin, Long, Short, PositionSide, ExecAction, HedgedMode
import .Misc: opposite, reset!, Misc
using .Instruments.Derivatives: Derivative
using Exchanges: LeverageTier, LeverageTiersDict, leverage_tiers, tier
import Exchanges: maxleverage, tier
using .Lang: @ifdebug
using Base: negate
import OrderTypes: isshort, islong, commit!, PositionUpdated, LeverageUpdated, MarginUpdated
import .Misc: marginmode
import .Instruments: cash!

@doc "A constant representing a vector of `DFT` type."
const OneVec = Vector{DFT}

@doc "A position has been opened."
struct PositionOpen <: ExecAction end
@doc "A position has been updated."
struct PositionUpdate <: ExecAction end
@doc "A position has been closed."
struct PositionClose <: ExecAction end
@doc "Position status is one of `PositionOpen`, `PositionClose`."
const PositionStatus = Union{PositionOpen,PositionClose}
@doc "Position change is one of `PositionOpen`, `PositionUpdate`, `PositionClose`."
const PositionChange = Union{PositionOpen,PositionUpdate,PositionClose}
opposite(::PositionOpen) = PositionClose()
opposite(::PositionClose) = PositionOpen()

@doc """ A position tracks the margin state of an asset instance.

$(FIELDS)
"""
@kwdef struct Position{P<:PositionSide,E<:ExchangeID,M<:MarginMode}
    "Current status of the position"
    status::Vector{PositionStatus} = [PositionClose()]
    "Asset being tracked"
    asset::Derivative
    "Timestamp of the last update"
    timestamp::Vector{DateTime} = [DateTime(0)]
    "Asset liquidation price"
    liquidation_price::OneVec = [0.0]
    "Price at which the position was entered"
    entryprice::OneVec = [0.0]
    "Maintenance margin required for the position"
    maintenance_margin::OneVec = [0.0]
    "Initial margin required for the position"
    initial_margin::OneVec = [0.0]
    "Additional margin required for the position"
    additional_margin::OneVec = [0.0]
    "Notional value of the position"
    notional::OneVec = [0.0]
    "Cash value of the position"
    cash::CCash{E}{S1} where {S1}
    "Cash committed to the position"
    cash_committed::CCash{E}{S2} where {S2}
    "Leverage applied to the position"
    leverage::OneVec = [1.0]
    "Minimum size of the position"
    min_size::T where {T<:Real}
    "Whether the position is hedged or not"
    hedged::Bool = false
    "Leverage tiers applicable to the position"
    tiers::Vector{LeverageTiersDict}
    "Current tier applicable to the position"
    this_tier::Vector{LeverageTier}
    function Position{P,E,M}(
        args...; kwargs...
    ) where {P<:PositionSide,E<:ExchangeID,M<:MarginMode}
        M == NoMargin && error("Trying to construct a position in `NoMargin` mode")
        new{P,E,M}(args...; kwargs...)
    end
end


exchangeid(::Position{<:PositionSide,E}) where {E<:ExchangeID} = E

@doc """ Resets position to initial state.

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

$(TYPEDSIGNATURES)

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

@doc "A constant representing a long position with margin in a specific exchange."
const LongPosition{E<:ExchangeID,M<:WithMargin} = Position{Long,E,M}
@doc "A constant representing a short position with margin in a specific exchange."
const ShortPosition{E<:ExchangeID,M<:WithMargin} = Position{Short,E,M}

@doc "The number of digits to keep for margin calculations."
const POSITION_PRECISION = 4
@doc "The number of digits allowed for leverage values."
const LEVERAGE_PRECISION = 2
@doc "A constant defining the rounding mode for positions as `RoundToZero`."
const POSITION_ROUNDING_MODE = RoundToZero

@doc """ Round function for values of position fields.

$(TYPEDSIGNATURES)

This function rounds the values of position fields to a specified precision. The default precision is `POSITION_PRECISION`.

"""
function _roundpos(v, digits=POSITION_PRECISION)
    round(v, POSITION_ROUNDING_MODE; digits)
end

_roundlev(po, lev) = _roundpos(clamp(lev, 1.0, maxleverage(po)), LEVERAGE_PRECISION)

@doc "Updates position leverage."
function leverage!(po::Position, v)
    @deassert maxleverage(po) == maxleverage(po, notional(po))
    po.leverage[] = _roundlev(po, v)
end

@doc """ Returns the maximum leverage for a given position and size.

$(TYPEDSIGNATURES)

The function retrieves the leverage tier applicable to the provided position and size, and returns the maximum leverage allowed within that tier.

"""
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
islong(::Missing) = false
isshort(::Position{Short}) = true
isshort(::Position{Long}) = false
isshort(::Union{Type{Short},Short}) = true
isshort(::Union{Type{Long},Long}) = false
isshort(::Missing) = false
Misc.marginmode(::Position{<:PositionSide,<:ExchangeID,M}) where {M<:MarginMode} = M()
function ishedged(::Position{<:PositionSide,<:ExchangeID,M}) where {M<:MarginMode}
    ishedged(M())
end
@doc """ Retrieves the leverage tier for a given position and size.

$(TYPEDSIGNATURES)

This function returns the tier that applies to a position of the provided size.

"""
function tier(po::Position, size)
    # tier should work with abs values
    @deassert tier(po.tiers[], po.cash.value) == tier(po.tiers[], negate(po.cash.value))
    tier(po.tiers[], size)
end
posside(::Position{P}) where {P<:PositionSide} = P()
posside(::ByPos{P}) where {P<:PositionSide} = P()
function posside(::Type{<:Order{<:O,<:A,<:E,P}}) where {O,A,E,P<:PositionSide}
    P()
end

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
initial(args...; kwargs...) = margin(args...; kwargs...)
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
@doc "Maximum value that can be lost by the position"
collateral(po::Position) = margin(po) + additional(po)
@doc "Last position update time"
timestamp(po::Position) = po.timestamp[]

@doc """ The price where the position is fully liquidated.

$(TYPEDSIGNATURES)

This function calculates and returns the price at which a position, given its leverage (`lev`), would be fully liquidated.

"""
function bankruptcy(price::Real, lev::Real, ::Long)
    @deassert lev != 0.0
    price * (lev - 1.0) / lev
end
function bankruptcy(price::Real, lev::Real, ::Short)
    @deassert lev != 0.0
    price * (lev + 1.0) / lev
end
function bankruptcy(pos::Position{P}, price) where P<:PositionSide
    lev = leverage(pos)
    bankruptcy(price, lev, P())
end
function bankruptcy(pos::Position, o::Order{T,A,E,P}) where {T,A,E,P<:PositionSide}
    bankruptcy(pos, o.price)
end

@doc """ Updates the timestamp of a position.

$(TYPEDSIGNATURES)

This function sets the timestamp of a given position (`po`) to the provided DateTime value (`d`).

"""
function timestamp!(po::Position, d::DateTime)
    @deassert po.timestamp[] <= d "Position dates can only go forward.($(po.timestamp[]), $d)"
    po.timestamp[] = d
end

@doc """ Updates position leverage tier according to size.

$(TYPEDSIGNATURES)

This function adjusts the leverage tier of a given position (`po`) based on the provided size. If no size is provided, the notional value of the position is used.

"""
function tier!(po::Position, size=notional(po))
    po.this_tier[] = tier(po, size)[2]
end

@doc "Update the entry price.

$(TYPEDSIGNATURES)
"
function entryprice!(po::Position, v=abs(notional(po) / cash(po)))
    po.entryprice[] = v
end

@doc """ Update the notional value.

$(TYPEDSIGNATURES)

This function updates the notional value of a given position (`po`) to the provided value (`v`).

"""
function notional!(po::Position, v)
    @ifdebug v < 0.0 && @warn "Notional value should never be negative ($v)"
    po.notional[] = abs(v)
    # update leverage tier after notional update
    tier!(po)
    v
end

@doc """ Sets initial margin given notional and leverage values.

$(TYPEDSIGNATURES)

This function sets the initial margin of a given position (`po`) based on the provided notional value (`ntl`) and leverage (`lev`). If no values are provided, the current notional value and leverage of the position are used.

"""
function margin!(po::Position; ntl=notional(po), lev=leverage(po))
    m = _roundpos(ntl / lev)
    @deassert m <= notional(po)
    po.initial_margin[] = m
end

@doc """ Sets initial margin (should always be positive).

$(TYPEDSIGNATURES)

This function sets the initial margin of a given position (`po`) to the provided value (`v`). If no value is provided, it defaults to 0.0.

"""
function initial!(po::Position, v=0.0)
    po.initial_margin[] = abs(v) |> _roundpos
end

@doc """ Sets additional margin (should always be positive).

$(TYPEDSIGNATURES)

This function sets the additional margin of a given position (`po`) to the provided value (`v`). If no value is provided, it defaults to 0.0.

"""
function additional!(po::Position, v=0.0)
    @deassert v + margin(po) <= notional(po)
    po.additional_margin[] = abs(v) |> _roundpos
end

@doc """ Adds margin to a position.

$(TYPEDSIGNATURES)

This function adds a specified amount (`v`) to the margin of a given position (`po`).

"""
function addmargin!(po::Position, v)
    @deassert margin(po) + v <= notional(po)
    po.additional_margin[] = max(0.0, v + additional(po)) |> _roundpos
end

@doc """ Sets maintenance margin.

$(TYPEDSIGNATURES)

This function sets the maintenance margin of a given position (`po`) to the provided value (`v`).

"""
function maintenance!(po::Position, v)
    po.maintenance_margin[] = _roundpos(v)
    @deassert maintenance(po) <= margin(po)
    v
end

@doc "Set position cash value."
Instruments.cash!(po::Position, v) = cash!(cash(po), v)
@doc "Set position committed cash value."
OrderTypes.commit!(po::Position, v) = cash!(committed(po), v)

@doc """ Calc PNL for long position given `current_price` as input.

$(TYPEDSIGNATURES)

This function calculates the Profit and Loss (PNL) for a long position (`po`), given the current price (`current_price`) and an optional amount (`amount`). If no amount is provided, the cash value of the position is used.

"""
function pnl(po::Position{Long}, current_price, amount=cash(po))
    @deassert notional(po) ~= abs(cash(po)) * price(po)
    isopen(po) || return 0.0
    pnl(price(po), current_price, amount, Long())
end

@doc """ Calc PNL for short position given `current_price` as input.

$(TYPEDSIGNATURES)

This function calculates the Profit and Loss (PNL) for a short position (`po`), given the current price (`current_price`) and an optional amount (`amount`). If no amount is provided, the cash value of the position is used.

"""
function pnl(po::Position{Short}, current_price, amount=cash(po))
    isopen(po) || return 0.0
    pnl(price(po), current_price, amount, Short())
end

@doc """ Calc PNL percentage.

$(TYPEDSIGNATURES)

This function calculates the Profit and Loss (PNL) percentage for a given position (`po`) and value (`v`).

"""
pnlpct(po::Position, v) = begin
    isopen(po) || return 0.0
    pnl(po, v, 1.0) / price(po)
end

@doc """ Calculate PNL for a long position.

$(TYPEDSIGNATURES)

This function calculates the Profit and Loss (PNL) for a long position, given the entry price (`entryprice`), the current price (`current_price`), and the amount.

"""
function pnl(entryprice::T, current_price::T, amount, ::ByPos{Long}) where {T}
    (current_price - entryprice) * abs(amount)
end

@doc """ Calculate PNL for a short position.

$(TYPEDSIGNATURES)

This function calculates the Profit and Loss (PNL) for a short position, given the entry price (`entryprice`), the current price (`current_price`), and the amount.

"""
function pnl(entryprice::T, current_price::T, amount, ::ByPos{Short}) where {T}
    (entryprice - current_price) * abs(amount)
end

@doc """ Sets the liquidation price for a long position.

$(TYPEDSIGNATURES)

This function sets the liquidation price of a given long position (`po`) to the provided value (`v`).

"""
function liqprice!(po::Position{Long}, v)
    @deassert v <= price(po)
    po.liquidation_price[] = v
end

@doc """ Sets the liquidation price for a short position.

$(TYPEDSIGNATURES)

This function sets the liquidation price of a given short position (`po`) to the provided value (`v`).

"""
function liqprice!(po::Position{Short}, v)
    @deassert v >= price(po) (v, price(po))
    po.liquidation_price[] = v
end

function Base.print(io::IO, po::Position)
    write(io, "Position($(posside(po)), $(po.asset))\n")
    write(io, "entryprice: ")
    write(io, string(price(po)))
    write(io, "\namount: ")
    write(io, string(cash(po)))
    write(io, "\nnotional: ")
    write(io, string(notional(po)))
    write(io, "\ncollateral: ")
    write(io, string(collateral(po)))
    write(io, "\nleverage: ")
    write(io, string(leverage(po)))
    write(io, "\nmaintenance: ")
    write(io, string(maintenance(po)))
    write(io, "\nliquidation price: ")
    write(io, string(liqprice(po)))
    write(io, "\ndate: ")
    write(io, string(po.timestamp[]))
end

Base.show(io::IO, ::MIME"text/plain", po::Position) = print(io, po)
Base.show(io::IO, po::Position) = print(io, po)

function PositionUpdated(tag, group, pos::Position)
    PositionUpdated{exchangeid(pos)}(
        Symbol(tag),
        Symbol(group),
        raw(pos.asset),
        (posside(pos), isopen(pos)),
        timestamp(pos),
        liqprice(pos),
        entryprice(pos),
        maintenance(pos),
        initial(pos),
        leverage(pos),
        notional(pos),
    )
end

# TODO: add `AddMargin` pong! function
function MarginUpdated(tag, group, pos::Position; from_value::DFT=0.0)
    MarginUpdated{exchangeid(pos)}(
        Symbol(tag),
        Symbol(group),
        raw(pos.asset),
        posside(pos),
        timestamp(pos),
        string(marginmode(pos)),
        from_value,
        margin(pos),
    )
end

function LeverageUpdated(tag, group, pos::Position; from_value::DFT=one(0.0))
    LeverageUpdated{exchangeid(pos)}(
        Symbol(tag),
        Symbol(group),
        raw(pos.asset),
        posside(pos),
        timestamp(pos),
        from_value,
        leverage(pos),
    )
end

export notional, additional, price, bankruptcy, pnl, collateral
export status, timestamp, tier
export timestamp!, leverage!, tier!
export liqprice!, margin!, maintenance!, initial!, additional!, notional!
export PositionOpen, PositionClose, PositionUpdate, PositionStatus, PositionChange
