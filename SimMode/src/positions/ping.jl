import .Strategies: ping!

@doc """
After a position was updated from a trade.

$(TYPEDSIGNATURES)

This function is called after a position is updated due to a trade. It takes in a `MarginStrategy`, `ai`, `trade`, `Position`, and `PositionChange` as arguments. The function does not return any value.

"""
function ping!(::MarginStrategy, ai, trade::Trade, ::Position, ::PositionChange)
    nothing
end

@doc """
After a position update from a candle.

$(TYPEDSIGNATURES)

This function is called after a position is updated from a candle. It provides the necessary functionality for handling position updates in response to candle data.

"""
function ping!(::MarginStrategy, ai, date::DateTime, ::Position, ::PositionUpdate)
    nothing
end
