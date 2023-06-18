using Exchanges.Ccxt: _multifunc
using Exchanges.Misc: LittleDict
@enum OrderBookLevel L1 L2 L3
Base.convert(::Type{OrderBookLevel}, v::Integer) = OrderBookLevel(v)

const MAX_ORDERS = [5, 10, 20, 50, 100, 500, 1000]
const OB_FUNCTIONS = LittleDict{Tuple{OrderBookLevel,ExchangeID},Py}()
const OB_TTL = Ref(Second(5))
const OB_EVICTION_TTL = Ref(Minute(5))
const OrderBookTuple4 = NamedTuple{
    (:timestamp, :asks, :bids),
    Tuple{Ref{DateTime},Vector{Tuple{DFT,DFT}},Vector{Tuple{DFT,DFT}}},
}
const OB_CACHE6 = safettl(
    Tuple{OrderBookLevel,ExchangeID}, OrderBookTuple4, OB_EVICTION_TTL[]
)

function _orderbook(N)
    OrderBookTuple4((
        Ref(DateTime(0)), Vector{Tuple{DFT,DFT}}(undef, N), Vector{Tuple{DFT,DFT}}(undef, N)
    ))
end
_levelname(level) =
    let lvl = convert(OrderBookLevel, level)
        if lvl == L1
            "OrderBook"
        elseif lvl == L2
            "L2OrderBook"
        else
            "L3OrderBook"
        end
    end

Base.convert(::Type{OrderBookLevel}, n::Integer) = OrderBookLevel(n - 1)

function _update_orderbook!(ob, sym, lvl, limit)
    f = @lget! OB_FUNCTIONS (lvl, exc.id) _multifunc(exc, _levelname(lvl), true)[1]
    py_ob = pyfetch(f, sym; limit)
    ob.timestamp[] = pyconvert(DateTime, py_ob["timestamp"])
    let asks = ob.asks
        empty!(asks)
        for a in py_ob["asks"]
            push!(asks, pyconvert(Tuple{DFT,DFT}, a))
        end
    end
    let bids = ob.bids
        empty!(bids)
        for b in py_ob["bids"]
            push!(bids, pyconvert(Tuple{DFT,DFT}, b))
        end
    end
    ob
end

function orderbook(exc, sym; limit=100, level=L1)
    lvl = convert(OrderBookLevel, level)
    ob = @lget! OB_CACHE6 (lvl, exc.id) begin
        limit = min(7, searchsortedlast(MAX_ORDERS, limit))
        ob = _orderbook(limit)
        sizehint!(ob.asks, limit)
        sizehint!(ob.bids, limit)
        _update_orderbook!(ob, sym, lvl, limit)
    end
    if now() > ob.timestamp[] + OB_TTL[]
        _update_orderbook!(ob, sym, lvl, limit)
    end
    ob
end
