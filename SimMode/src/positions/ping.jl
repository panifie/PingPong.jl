import Strategies: ping!

@doc "After a position update"
function ping!(::MarginStrategy, ai, trade, ::Position, ::PositionChange)
    nothing
end

