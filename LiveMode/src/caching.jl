using LRUCache: LRUCache
using .Misc.TimeToLive: ConcurrentDict

_last_trade_date(ai) = st.lasttrade_date(ai, now() - Day(1))
function somevalue(dict, keys...)
    for k in keys
        v = get(dict, k, nothing)
        isnothing(v) || return v
    end
end

ttl_dict_type(ttl::Period, kt=DateTime, vt=Vector{Any}) = TTL{kt,Union{Missing,vt},ConcurrentDict,typeof(ttl)}
ttl_resp_dict(ttl::Period, kt=DateTime, vt=Vector{Any}) = safettl(kt, Union{Missing,vt}, ttl)

function _trades_resp_cache(a, ai)
    # every asset instance holds a mapping of timestamp (since) and relative vector of trades resps
    cache = @lget! a :trades_cache Dict{AssetInstance,ttl_dict_type(a[:trades_cache_ttl])}()
    @lget! cache ai ttl_resp_dict(a[:trades_cache_ttl])
end

@doc """Use `DateTime(0)` as key to fetch the *latest* response."""
const LATEST_RESP_KEY = DateTime(0)

function _order_trades_resp_cache(a, ai)
    cache = @lget! a :trades_cache Dict{AssetInstance,ttl_dict_type(a[:trades_cache_ttl], String)}()
    @lget! cache ai ttl_resp_dict(a[:trades_cache_ttl], String)
end

function _open_orders_resp_cache(a, ai)
    cache = @lget! a :open_orders_cache Dict{AssetInstance,ttl_dict_type(a[:open_orders_ttl])}()
    @lget! cache ai ttl_resp_dict(a[:open_orders_ttl])
end

function _closed_orders_resp_cache(a, ai)
    cache = @lget! a :closed_orders_cache Dict{AssetInstance,ttl_dict_type(a[:closed_orders_ttl], Union{String,DateTime})}()
    @lget! cache ai ttl_resp_dict(a[:closed_orders_ttl], Union{String,DateTime})
end

function _orders_resp_cache(a, ai)
    cache = @lget! a :orders_cache Dict{AssetInstance,ttl_dict_type(a[:orders_cache_ttl], Any)}()
    @lget! cache ai ttl_resp_dict(a[:orders_cache_ttl], Any)
end

function _order_byid_resp_cache(a, ai)
    cache = @lget! a :order_byid_cache Dict{AssetInstance,ttl_dict_type(a[:order_byid_ttl], String)}()
    @lget! cache ai ttl_resp_dict(a[:order_byid_ttl], String)
end

function _positions_resp_cache(a)
    lock = ReentrantLock()
    @lget! a :positions_cache (; lock, data=ttl_resp_dict(a[:positions_ttl], Any, Any))
end

function _func_cache(a)
    @lget! a :fetchall_cache (ReentrantLock(),
        Dict{Symbol,
            Tuple{ReentrantLock,
                ttl_dict_type(a[:orders_cache_ttl], DateTime, Any)}}()
    )
end
function _func_cache(a, func)
    l, cache = _func_cache(a)
    @lock l @lget! cache func (ReentrantLock(), ttl_resp_dict(a[:func_cache_ttl], DateTime, Any))
end

function save_strategy_cache(s; inmemory=false, cache_path=nothing)
    cache = Dict()
    for k in (:trades_cache, :open_orders_cache, :closed_orders_cache, :orders_cache, :order_byid_cache)
        if k in keys(s)
            cache[k] = s[k]
        end
    end
    if inmemory
        Main.strategy_cache = cache
    else
        Data.Cache.save_cache("strategy_cache", cache; cache_path)
    end
    return s
end

function load_strategy_cache(s, cache_path=nothing, raise=false)
    cache = if isdefined(Main, :strategy_cache)
    else
        Data.Cache.load_cache("strategy_cache"; cache_path, raise)
    end
    if cache isa Dict
        merge!(s.attrs, cache)
    end
    return s
end

@doc "An lru cache of recently processed orders ids."
const RecentOrdersDict = LRUCache.LRU{Union{UInt64,String},Nothing}
@doc """ Retrieves recent orders ids for a live strategy.

$(TYPEDSIGNATURES)

Returns a dictionary of recent orders ids for a given asset instance.

"""
function recent_orders(s::LiveStrategy, ai)
    lro = @lget! attrs(s) :live_recent_orders Dict{AssetInstance,RecentOrdersDict}()
    @lget! lro ai RecentOrdersDict(maxsize=100)
end

@doc "An lru cache of recently processed trades hashes."
const RecentUpdatesDict = LRUCache.LRU{UInt64,Nothing}

function recent_trade_update(s::LiveStrategy, ai)
    lrt = @lget! attrs(s) :live_recent_trades_update Dict{AssetInstance,RecentUpdatesDict}()
    @lget! lrt ai RecentUpdatesDict(maxsize=100)
end
