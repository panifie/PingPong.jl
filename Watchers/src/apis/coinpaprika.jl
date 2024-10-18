module CoinPaprika
using ..Watchers
using HTTP
using URIs
using JSON3
using ..Data: Candle
using ..Misc: Config, config, queryfromstruct
using ..Lang: Option, @kget!
using ..TimeTicks
using ..Watchers: jsontodict

API_URL = "https://api.coinpaprika.com/"
API_HEADERS = ["Accept-Encoding" => "deflate,gzip", "Accept" => "application/json"]

apiPaths = (;
    glob="/v1/global", coins="/v1/coins", tickers="/v1/tickers", exchanges="/v1/exchanges"
)

last_query = Ref(now())
const query_stack = Ref(0)
const limit = Millisecond(25 * 1000)
@doc """ CoinPaprika free plan is 25k queries per month, which is 1q/25s.

On every call we check when the last query was performed, and add available queries
that weren't used on a counter, to allow for bursts.

!!! warning "Not precise"
    Coinpaprika does not expose credits consumed by each endpoint, so we assume all calls are equals (2/min).
"""
ratelimit() = begin
    past = (now() - last_query[])
    if past < limit
        if query_stack[] > 0
            query_stack[] -= 1
        else
            sleep(limit - past)
            last_query[] = now()
        end
    else
        query_stack[] += past ÷ limit - 1
        last_query[] = now()
    end
end
@doc """ Manually add available api calls (mostly for debugging).

"""
addcalls!(n=100) = query_stack[] += n

function get(path::T where {T}, query=nothing)
    ratelimit()
    resp = HTTP.get(absuri(path, API_URL); query, headers=API_HEADERS)
    if resp.status == 429
        query_stack[] = 0
    end
    @assert resp.status == 200
    json = JSON3.read(resp.body)
    json
end

_check_error(json) = begin
    "error" ∉ keys(json)
end
_parse_date(s) = parse(DateTime, rstrip(s, 'Z'))

glob() = begin
    json = get(apiPaths.glob)
    _check_error(json)
    json
end

const coins_cache = Dict{String,Dict{String,Any}}()
const coins_syms = Dict{String,Vector{SubString}}()
@doc """ Load all coin ids.


"""
loadcoins!() = begin
    if isempty(coins_cache)
        json = get(apiPaths.coins)
        _check_error(json)
        for coin in json
            c = jsontodict(coin)
            id = c["id"]
            coins_cache[id] = c
            ls = lowercase(c["symbol"])
            push!(@kget!(coins_syms, ls, SubString[]), id)
        end
    end
    coins_cache
end

@doc "Get all coinpaprika item id matching by its symbol."
function idbysym(sym, ::Bool)
    loadcoins!()
    @something Base.get(coins_syms, lowercase(string(sym)), nothing) []
end
@doc "Get the first coinpaprika item id by its symbol."
idbysym(sym) = begin
    match = idbysym(sym, true)
    @assert !isempty(match) "$sym not a valid coinpaprika id."
    first(match)
end

check_coin_id(id) = begin
    @assert id ∈ keys(loadcoins!()) "Not a valid coin id or coins list not loaded (call `loadcoins!`)"
end


@doc """ Get last ~50 tweets for coin.


"""
twitter(id) = begin
    path = (apiPaths.coins, "/", id, "/twitter")
    json = get(join(path))
    _check_error(json)
    json
end

@doc """ Get all exchanges for specified coin.


"""
coin_exchanges(id) = begin
    path = (apiPaths.coins, "/", id, "/exchanges")
    json = get(join(path))
    Dict(begin
        itm = jsontodict(item)
        itm["id"] => itm
    end for item in json)
end

@doc """ Returns all markets for give coin (interpreted as *base* currency).

!!! warning "Expensive call"
    Don't call too often.

"""
coin_markets(id) = begin
    path = (apiPaths.coins, "/", id, "/markets")
    json = get(join(path))
    data = Dict{String,Vector{Dict}}()
    for item in json
        itm = jsontodict(item)
        coin_id = itm["base_currency_id"]
        coin_id ∉ keys(data) && (data[coin_id] = Vector{Dict}())
        push!(data[coin_id], jsontodict(itm))
    end
    data
end
@doc """ Coin ohlcv (last day).

- `incomplete`: if `true` returns the (today) incomplete candle.
"""
function coin_ohlcv(id; incomplete=false, qc="usd")
    path = (apiPaths.coins, "/", id, "/ohlcv/", incomplete ? "today" : "latest")
    json = get(join(path), ("quote" => qc,))
    json = json[1]
    Candle(
        _parse_date(json["time_open"]),
        Float64(json["open"]),
        Float64(json["high"]),
        Float64(json["low"]),
        Float64(json["close"]),
        Float64(json["volume"]),
    )
end

ticker_dict(json) = begin
    quotes = Dict{String,Float64}()
    for (k, v) in json["quotes"]["USD"]
        if k == :ath_date
            quotes[string(k)] = _parse_date(v)
        else
            quotes[string(k)] = v
        end
    end
    quotes["beta"] = json["beta_value"]
    quotes
end

@doc "Fetch quotes for all pairs, includes coinpaprika `beta` metric."
function tickers(qc="usd")
    json = get(apiPaths.tickers, ("quotes" => qc))
    Dict(String(t["id"]) => ticker_dict(t) for t in json)
end

@doc "Fetch ticker for specified coin."
function ticker(id)
    check_coin_id(id)
    path = (apiPaths.tickers, "/", id)
    json = get(join(path))
    ticker_dict(json)
end

@doc "Returns coins betas in a dataframe compatible type."
betas() = begin
    data = tickers()
    (coins, betas) = (String[], Float64[])
    for (k, tk) in data
        push!(coins, k)
        push!(betas, tk["beta"])
    end
    (; coins, betas)
end

@doc """ Returns historical hourly tick values for the last day.

"""
function hourly(id, qc="usd")
    check_coin_id(id)
    path = (apiPaths.tickers, "/", id, "/historical")
    start = string(Int(trunc(datetime2unix(now() - Minute(1439)))))
    json = get(join(path), ("quote" => qc, "interval" => "1h", "start" => start))
    _check_error(json)
    res = (; timestamp=DateTime[], price=Float64[], volume24=Float64[])
    for i in json
        push!(res.price, i["price"])
        push!(res.volume24, i["volume_24h"])
        push!(res.timestamp, _parse_date(i["timestamp"]))
    end
    res
end

const exchanges_cache = Dict{String,String}()
@doc """ Load market ids.

"""
function loadexchanges!()
    if isempty(exchanges_cache)
        json = get(apiPaths.exchanges)
        for v in json
            exchanges_cache[v["id"]] = v["name"]
        end
    end
    exchanges_cache
end

check_exc_id(id) =
    @assert id ∈ keys(loadexchanges!()) "Not a valid exchange id or exchange ids not loaded, (call `loadexchanges!`)"

@doc """ Fetch all markets for specified exchange.
"""
function markets(exc_id, qc="usd")
    check_exc_id(exc_id)
    path = (apiPaths.exchanges, "/", exc_id, "/markets")
    json = get(join(path), ("quote" => qc))
    data = Dict{String,Any}()
    for v in json
        pair = v["pair"] * ":" * v["category"]
        @assert pair ∉ keys(data)
        data[pair] = v
    end
    data
end

end
