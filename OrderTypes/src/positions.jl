using .Misc: DFT

abstract type PositionEvent{E} <: ExchangeEvent{E} end

@doc "A position snapshot represents the state of a position *after* some `ExchangeEvent` has happened.

$(FIELDS)
"
struct PositionUpdated{E} <: PositionEvent{E}
    tag::Symbol
    asset::String
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
struct MarginUpdated{E} <: PositionEvent{E}
    tag::Symbol
    asset::String
    mode::String
    from::DFT
    value::DFT
end

@doc "Updating the leverage of a position implies also adjusting its liquidation price, notional, .

$(FIELDS)
"
struct LeverageUpdated{E} <: PositionEvent{E}
    tag::Symbol
    asset::String
    from::DFT
    value::DFT
end

@doc """ Represents a position opened event.

$(TYPEDSIGNATURES)

This event is triggered when a position is opened.
"""
struct PositionOpened{E} <: PositionEvent{E}
    tag::Symbol
    timestamp::DateTime
end

@doc """ Represents a position closed event.

$(TYPEDSIGNATURES)

This event is triggered when a position is closed.
"""
struct PositionClosed{E} <: PositionEvent{E}
    tag::Symbol
    timestamp::DateTime
end
