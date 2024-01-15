using LRUCache: LRUCache
using .Misc.TimeToLive: ConcurrentDict

_last_trade_date(ai) = isempty(trades(ai)) ? now() - Day(1) : last(trades(ai)).date

function somevalue(dict, keys...)
    for k in keys
        v = get(dict, k, nothing)
        isnothing(v) || return v
    end
end

ttl_dict_type(ttl::Period, kt=DateTime) = TTL{kt,Union{Missing,Vector{Any}},ConcurrentDict,typeof(ttl)}
ttl_resp_dict(ttl::Period, kt=DateTime) = safettl(kt, Union{Missing,Vector{Any}}, ttl)

function _trades_resp_cache(a, ai)
    # every asset instance holds a mapping of timestamp (since) and relative vector of trades resps
    cache = @lget! a :trades_cache Dict{AssetInstance,ttl_dict_type(a[:trades_cache_ttl])}()
    @lget! cache ai ttl_resp_dict(a[:trades_cache_ttl])
end

function _order_trades_resp_cache(a, ai)
    # every asset instance holds a mapping of timestamp (since) and relative vector of trades resps
    cache = @lget! a :trades_cache Dict{AssetInstance,ttl_dict_type(a[:trades_cache_ttl])}()
    @lget! cache ai ttl_resp_dict(a[:trades_cache_ttl])
end

function _open_orders_resp_cache(a, ai)
    # every asset instance holds a mapping of timestamp (since) and relative vector of trades resps
    cache = @lget! a :open_orders_cache Dict{AssetInstance,ttl_dict_type(a[:open_orders_ttl])}()
    @lget! cache ai ttl_resp_dict(a[:open_orders_ttl])
end

function _closed_orders_resp_cache(a, ai)
    # every asset instance holds a mapping of timestamp (since) and relative vector of trades resps
    cache = @lget! a :closed_orders_cache Dict{AssetInstance,ttl_dict_type(a[:closed_orders_ttl], Union{String,DateTime})}()
    @lget! cache ai ttl_resp_dict(a[:closed_orders_ttl], Union{String,DateTime})
end

function _orders_resp_cache(a, ai)
    # every asset instance holds a mapping of timestamp (since) and relative vector of trades resps
    cache = @lget! a :orders_cache Dict{AssetInstance,ttl_dict_type(a[:orders_ttl], Any)}()
    @lget! cache ai ttl_resp_dict(a[:orders_ttl], Any)
end

function _order_byid_resp_cache(a, ai)
    # every asset instance holds a mapping of timestamp (since) and relative vector of trades resps
    cache = @lget! a :order_byid_cache Dict{AssetInstance,ttl_dict_type(a[:order_byid_ttl], String)}()
    @lget! cache ai ttl_resp_dict(a[:order_byid_ttl], String)
end

@doc "An lru cache of recently processed orders ids."
const RecentOrdersDict = LRUCache.LRU{String,Nothing}
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
