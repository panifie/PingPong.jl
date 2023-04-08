using Lang: @ifdebug
using Python: @pystr
using OrderTypes
using OrderTypes: LimitOrderType, MarketOrderType

_ccxtordertype(::LimitOrder) = @pystr "limit"
_ccxtordertype(::MarketOrder) = @pystr "market"
_ccxtorderside(::BuyOrder) = @pystr "buy"
_ccxtorderside(::SellOrder) = @pystr "buy"

function createorder(exc::Exchange, o)
    sym = o.asset.raw
    type = _ccxtordertype(o)
    side = _ccxtorderside(o)
    price = o.price
    amount = o.amount
    ccxt_order = @pyfetch exc.py.createOrder(sym, type, side, amount, price)
    id = ccxt_order.get("id", "")
    @ifdebug begin
        resp = exc.py.fetchOrder(id, sym)
        @assert resp["side"] == side
        @assert resp["type"] == type
        @assert resp["price"] ≈ price
        @assert resp["amount"] ≈ amount
    end
end

function orders(ai::AssetInstance)
   @pyfetch ai.exchange.fetchOrders()
end
