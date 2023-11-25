using .Misc: DFT

abstract type PositionUpdate{E} <: AssetEvent{E} end

@doc "A position snapshot represents the state of a position *after* some `ExchangeEvent` has happened.

$(FIELDS)
"
struct PositionSnapshot{A<:AbstractAsset,E<:ExchangeID,P<:PositionSide}
    asset::A
    timestamp::DateTime
    liquidation_price::DFT
    entryprice::DFT
    maintenance_margin::DFT
    initial_margin::DFT
    leverage::DFT
    notional::DFT
end

@doc "Updating the margin of a position implies also adjusting its liquidation price.

$(FIELDS)
"
struct MarginUpdate{A<:AbstractAsset,E<:ExchangeID,P<:PositionSide} <: PositionUpdate{E}
    asset::A
    position::PositionSnapshot{A,E,P}
    value::DFT
end

@doc "Updating the leverage of a position implies also adjusting its liquidation price, notional, .

$(FIELDS)
"
struct LeverageUpdate{A<:AbstractAsset,E<:ExchangeID,P<:PositionSide} <: PositionUpdate{E}
    asset::A
    position::PositionSnapshot{A,E,P}
    value::DFT
end
