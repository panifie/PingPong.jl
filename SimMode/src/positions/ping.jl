import Strategies: ping!

function ping!(
    ::Strategy{<:ExecMode,N,<:ExchangeID,<:WithMargin}, ai, trade, ::Position, ::PositionChange
) where {N}
    nothing
end
