using .Lang: @ifdebug
using .Python: @pystr
using .OrderTypes
using .OrderTypes: LimitOrderType, MarketOrderType

_ccxtordertype(::LimitOrder) = @pystr "limit"
_ccxtordertype(::MarketOrder) = @pystr "market"
_ccxtorderside(::Type{Buy}) = @pystr "buy"
_ccxtorderside(::Type{Sell}) = @pystr "sell"
_ccxtorderside(::Union{AnyBuyOrder,Type{<:AnyBuyOrder}}) = @pystr "buy"
_ccxtorderside(::Union{AnySellOrder,Type{<:AnySellOrder}}) = @pystr "buy"

function createorder(exc::Exchange, o)
    sym = o.asset.raw
    type = _ccxtordertype(o)
    side = _ccxtorderside(o)
    price = o.price
    amount = o.amount
    ccxt_order = @pyfetch exc.py.createOrder(sym, type, side, amount, price)
    id = get_py(ccxt_order, "id", "")
    @ifdebug begin
        resp = exc.py.fetchOrder(id, sym)
        @assert resp["side"] == side
        @assert resp["type"] == type
        @assert resp["price"] ≈ price
        @assert resp["amount"] ≈ amount
    end
end

# function orders(s::LiveStrategy, ai::AssetInstance)
#    fetch_orders(s, )
#    s[:live_orders_func](ai)
# end
