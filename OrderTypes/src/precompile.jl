using .Lang: @preset, @precomp

@preset let
    a = Instruments.parse(Asset, "BTC/USDT")
    e = ExchangeID(:bybit)
    date = dt"2020-01-"
    for T in (MarketOrderType, GTCOrderType, IOCOrderType, FOKOrderType), S in (Buy, Sell)
        @precomp begin
            o = Order(a, e, Order{T{S}}; price=10.0, date, amount=100.0, attrs=(;))
            hash(o)
            orderside(o)
            ordertype(o)
            Trade(o; date, amount=10.0, price=10.0, fees=0.0, size=10.0, lev=1.0)
            NotEnoughCash(0.1)
            OrderTimeOut(o)
            NotMatched(0.1, 0.1, 0.1, 0.1)
            NotFilled(0.1, 0.1)
            OrderFailed("abc")
        end
    end
end
