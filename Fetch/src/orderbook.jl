using Exchanges: ExchangeID, pyfetch_timeout
using Exchanges.Ccxt: _multifunc
using Exchanges.Misc: LittleDict, @tspawnat
@enum OrderBookLevel L1 L2 L3
Base.convert(::Type{OrderBookLevel}, n::Integer) = OrderBookLevel(n - 1)

const MAX_ORDERS = [5, 10, 20, 50, 100, 500, 1000]
const OB_FUNCTIONS = LittleDict{Tuple{OrderBookLevel,ExchangeID},Py}()
const OB_TTL = Ref(Second(5))
const OB_EVICTION_TTL = Ref(Minute(5))
const OrderBookTuple = NamedTuple{
    (:busy, :timestamp, :asks, :bids),
    Tuple{Ref{Bool},Ref{DateTime},Vector{Tuple{DFT,DFT}},Vector{Tuple{DFT,DFT}}},
}
const OB_CACHE = safettl(
    Tuple{String,OrderBookLevel,ExchangeID}, OrderBookTuple, OB_EVICTION_TTL[]
)

function _orderbook(N)
    OrderBookTuple((
        Ref(false),
        Ref(DateTime(0)),
        Vector{Tuple{DFT,DFT}}(undef, N),
        Vector{Tuple{DFT,DFT}}(undef, N),
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

function _update_orderbook!(exc, ob, sym, lvl, limit; init)
    ob.busy[] && return ob
    f = @lget! OB_FUNCTIONS (lvl, exc.id) _multifunc(exc, _levelname(lvl), true)[1]
    t = @tspawnat 1 begin
        ob.busy[] = true
        try
            py_ob = pyfetch_timeout(
                f,
                getproperty(exc.py, string("fetch", _levelname(lvl))),
                Second(2),
                sym;
                limit,
            )
            ob.timestamp[] = dt(pyconvert(Int, pyint(py_ob["timestamp"])))
            let asks = ob.asks
                empty!(asks)
                for a in py_ob["asks"]
                    push!(asks, (pytofloat(a[0]), pytofloat(a[1])))
                end
            end
            let bids = ob.bids
                empty!(bids)
                for b in py_ob["bids"]
                    push!(bids, (pytofloat(b[0]), pytofloat(b[1])))
                end
            end
        finally
            ob.busy[] = false
        end
    end
    if init
        wait(t)
    else
        slept = 0.0
        while !istaskdone(t) && slept < 0.5
            sleep(0.1)
            slept += 0.1
        end
    end
    ob
end

function orderbook(exc, sym; limit=100, level=L1)
    lvl = convert(OrderBookLevel, level)
    ob = @lget! OB_CACHE (sym, lvl, exc.id) begin
        limit = MAX_ORDERS[min(7, searchsortedlast(MAX_ORDERS, limit))]
        ob = _orderbook(limit)
        sizehint!(ob.asks, limit)
        sizehint!(ob.bids, limit)
        _update_orderbook!(exc, ob, sym, lvl, limit; init=true)
        ob
    end
    if now() > ob.timestamp[] + OB_TTL[]
        _update_orderbook!(exc, ob, sym, lvl, limit; init=false)
    end
    ob
end
