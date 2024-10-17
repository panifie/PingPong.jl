using .Misc.ConcurrentCollections: ConcurrentDict
using Fetch.Exchanges: ExchangeID

const OHLCV_CACHE_KEY = Tuple{ExchangeID,Symbol,Period,String}
const OHLCV_CACHE = ConcurrentDict{OHLCV_CACHE_KEY,DataFrame}()
const OHLCV_CACHE_LOCK = ReentrantLock()

function cached_ohlcv!(eid::ExchangeID, met::Symbol, period::Period, sym::String; def=nothing)
    @lget! OHLCV_CACHE (eid, met, period, sym) @lock OHLCV_CACHE_LOCK @lget! OHLCV_CACHE (
        eid, met, period, sym
    ) @something def empty_ohlcv()
end

function cached_ohlcv!(
    w::Watcher, met::Symbol; period=_tfr(w).period, sym=_sym(w), eid=_exc(w).id
)
    cached_ohlcv!(eid, met, period, sym)
end

function empty_cached_ohlcv!()
    @lock OHLCV_CACHE_LOCK begin
        empty!(OHLCV_CACHE)
    end
end
