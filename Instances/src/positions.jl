using Misc: MVector, MarginMode
using Instruments.Derivatives: Derivative

abstract type PositionSide end
struct Long <: PositionSide end
struct Short <: PositionSide end

const OneVec1 = MVector{1,T} where {T<:Union{DateTime,Real}}

@doc "A position tracks the margin state of an asset instance:
- `instance`: the underlying AssetInstance
- `timestamp`: last update time of the position (`DateTime`)
- `side`: the side of the position `<:PositionSide` `Long` or `Short`
For the rest of the fields refer to  [ccxt docs](https://docs.ccxt.com/#/README?id=position-structure)
"
@kwdef struct Position6{A<:AssetInstance,S<:PositionSide,M<:MarginMode}
    instance::A
    timestamp::OneVec1
    liquidation_price::OneVec1
    entryprice::OneVec1
    maintenance_margin::OneVec1
    initial_margin::OneVec1
    notional::OneVec1
    leverage::OneVec1
    side::PositionSide
    min_size::T where {T<:Real}
    # Position(s::Strategy, ai::AssetInstance; mode=s.margin)
end

Position = Position6
