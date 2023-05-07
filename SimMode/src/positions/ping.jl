import Strategies: ping!

function ping!(
    _::Strategy{<:ExecMode,N,<:ExchangeID,<:WithMargin}, _, _, ::Position, ::PositionOpen
) where {N}
    nothing
end
function ping!(
    _::Strategy{<:ExecMode,N,<:ExchangeID,<:WithMargin}, _, _, ::Position, ::PositionUpdate
) where {N}
    nothing
end
function ping!(
    _::Strategy{<:ExecMode,N,<:ExchangeID,<:WithMargin}, _, _, ::Position, ::PositionClose
) where {N}
    nothing
end
