import Strategies: ping!

@doc "After a position was updated from a trade. $(TYPEDSIGNATURES)"
function ping!(::MarginStrategy, ai, trade::Trade, ::Position, ::PositionChange)
    nothing
end

@doc "After a position update from a candle. $(TYPEDSIGNATURES)"
function ping!(::MarginStrategy, ai, date::DateTime, ::Position, ::PositionUpdate)
    nothing
end
