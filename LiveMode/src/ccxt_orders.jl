using .Lang: @ifdebug
using .Python: @pystr
using .OrderTypes
using .OrderTypes: LimitOrderType, MarketOrderType

_ccxtordertype(::LimitOrder) = @pystr "limit"
_ccxtordertype(::MarketOrder) = @pystr "market"
_ccxtorderside(::Type{Buy}) = @pystr "buy"
_ccxtorderside(::Type{Sell}) = @pystr "sell"
_ccxtorderside(::Union{AnyBuyOrder,Type{<:AnyBuyOrder}}) = @pystr "buy"
_ccxtorderside(::Union{AnySellOrder,Type{<:AnySellOrder}}) = @pystr "sell"
