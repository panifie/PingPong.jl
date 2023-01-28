module CoinGecko

using Base: unconstrain_vararg_length
using HTTP
using URIs
using Watchers
using LazyJSON
using TimeToLive: TTL
using Lang: @lget!, Option
using Misc
using TimeTicks
using TimeTicks: timestamp
using Instruments.Derivatives

API_URL = "https://api.coingecko.com"
API_HEADERS = ["Accept-Encoding" => "deflate,gzip", "Accept" => "application/json"]
ApiPaths = (;
    ping="/api/v3/ping",
    simple_price="/api/v3/simple/price",
    simple_vs="/api/v3/simple/supported_vs_currencies",
    coins_list="/api/v3/coins/list",
    coins_markets="/api/v3/coins/markets",
    coins_id="/api/v3/coins",
    exchanges="/api/v3/exchanges",
    exchanges_list="/api/v3/exchanges/list",
    indexes="/api/v3/indexes",
    indexes_list="/api/v3/indexes/list",
    derivatives="/api/v3/derivatives",
    derivatives_exchanges="/api/v3/derivatives/exchanges",
    rates="/api/v3/exchange_rates",
    search="/api/v3/search",
    trending="/api/v3/search/trending",
    glob="/api/v3/global"
)
const DEFAULT_CUR = "usd"

const last_query = Ref(DateTime(0))
const limit = Millisecond(3 * 1000)
@doc "Allows only 1 query every 3 seconds."
function ratelimit()
    sleep(max(Second(0), (last_query[] - now()) + limit))
end

function get(path::T where {T}, query=nothing)
    ratelimit()
    resp = HTTP.get(absuri(path, API_URL); query, headers=API_HEADERS)
    last_query[] = now()
    @assert resp.status == 200
    json = LazyJSON.value(resp.body)
    json
end

ping() = "gecko_says" ∈ keys(get(ApiPaths.ping))

function price(syms::AbstractVector, vs=[DEFAULT_CUR])
    json = get(
        ApiPaths.simple_price,
        (
            "ids" => join(string.(syms), ","),
            "vs_currencies" => vs,
            "include_24hr_vol" => true,
            "include_24hr_change" => true,
            "include_last_updated_at" => true,
        ),
    )
    convert(Dict{String,Dict{String,Any}}, json)
end

currencies = Set{String}()
function vs_currencies()
    if length(currencies) > 0
        currencies
    else
        json = get(ApiPaths.simple_vs)
        for el in json
            push!(currencies, el)
        end
        currencies
    end
end

coins = TTL{Nothing,Dict{String,String}}(Minute(60))
@doc "Load all coins symbols."
loadcoins!() = @lget! coins nothing begin
    json = get(ApiPaths.coins_list)
    @assert !isnothing(json)
    Dict{String,String}(d["id"] => d["symbol"] for d in json)
end

@enum SortBy begin
    gecko_desc
    gecko_asc
    market_cap_asc
    market_cap_desc
    volume_asc
    volume_desc
    id_asc
    id_desc
end

oneHour = "1h"
oneDay = "24h"
oneWeek = "7d"
twoWeeks = "14d"
oneMonth = "30d"
sixMonths = "200d"
oneYear = "1y"

@kwdef struct Paramss
    vs_currency = DEFAULT_CUR
    ids::Option{Vector{String}} = nothing
    order = volume_desc
    per_page = 100 # max 250
    page = 1
    price_change_percentage = [oneHour, oneDay, oneWeek, oneMonth, sixMonths]
end
Params = Paramss

@doc "Get markets for a list of symbols, accepting params `CoinGecko.Params`."
coinsmarkets(; kwargs...) = begin
    query = Misc.queryfromstruct(Params; kwargs...)
    json = get(ApiPaths.coins_markets, query)
    json
end

_is_valid(json) = !(json["is_stale"] || json["is_anomaly"])

@doc "Get all current data for symbol `id`."
coinsid(id::AbstractString) = begin
    get(join((ApiPaths.coins_id, "/", id)))
end

@doc "Get all tickers (from all coingecko exchanges) for symbol `id`."
coinsticker(id::AbstractString) = begin
    path = (ApiPaths.coins_id, "/", id, "/tickers")
    json = get(join(path))
    [t for t in json["tickers"] if _is_valid(t)]
end

_cg_dateformat(d::DateTime) = Dates.format(d, dateformat"dd-mm-yyyy")

function coinshistory(id::AbstractString, date::AbstractString)
    begin
        coinshistory(id, parse(DateTime, date))
    end
end
@doc "Get data for symbol `id` at specified date."
function coinshistory(id::AbstractString, date::DateTime, cur=DEFAULT_CUR)
    begin
        path = (ApiPaths.coins_id, "/", id, "/history")
        json = get(join(path), ("date" => _cg_dateformat(date),))
        data = json["market_data"]
        price = data["current_price"][cur] |> Float64
        volume = data["total_volume"][cur] |> Float64
        (; price, volume)
    end
end

function _parse_data(data)
    dates = DateTime[]
    prices = Float64[]
    volume = Float64[]
    vol_data = data["total_volumes"]
    for (n, (date, price)) in enumerate(data["prices"])
        push!(dates, dt(date))
        push!(prices, price)
        push!(volume, vol_data[n][2])
    end
    (; dates, prices, volume)
end

@doc """Get `close` price and volume for symbol `id` for specified number of days.
!! `days="max"
    returns all available history.
"""
function coinschart(id::AbstractString; days_ago="365", vs=DEFAULT_CUR)
    begin
        path = (ApiPaths.coins_id, "/", id, "/market_chart")
        json = get(join(path), ("days" => string(days_ago), "vs_currency" => vs))
        _parse_data(json)
    end
end

@doc """Same as [`CoinGecko.coinschart`](@ref) but for specified timerange.

 - `from`, `to`: date range boundaries.

 !! From coingecko:
    Data granularity is automatic (cannot be adjusted)
    1 day from current time = 5 minute interval data
    1 - 90 days from current time = hourly data
    above 90 days from current time = daily data (00:00 UTC)

 """
function coinschart_range(id::AbstractString; from, to=now(), vs=DEFAULT_CUR)
    begin
        path = (ApiPaths.coins_id, "/", id, "/market_chart/range")
        json = get(
            join(path),
            ("from" => timestamp(from), "to" => timestamp(to), "vs_currency" => vs),
        )
        _parse_data(json)
    end
end

@doc """Pull market data range according to timeframe.
- `5m`: 1 day
- `1h`: 90 days
- `>1h`: 365 days
"""
function coinschart_tf(id::AbstractString; timeframe::TimeFrame="5m", vs=DEFAULT_CUR)
    begin
        from = if timeframe <= tf"5m"
            now() - Day(1)
        elseif timeframe <= tf"1h"
            now() - Day(90)
        else
            now() - Day(365)
        end
        coinschart_range(id; from, vs)
    end
end

@doc """ Pulls ohlc data (no volumes) according to timeframe.

- `<=30m`: 1 day
- `<=4h`: 30 days
- `>4h`: max
"""
function coinsohlc(id::AbstractString, timeframe=tf"30m", vs=DEFAULT_CUR, as_mat=true)
    path = (ApiPaths.coins_id, "/", id, "/ohlc")
    days = if timeframe <= tf"30m"
        Day(1)
    elseif timeframe <= tf"4h"
        Day(30)
    else
        Day(99999)
    end
    json = get(join(path), ("days" => days.value, "vs_currency" => vs))
    vec = convert(Vector{Vector{Float64}}, json)
    if as_mat
        permutedims(splat(reduce)((hcat, vec)))
    else
        vec
    end
end

@doc "Returns global data for:

- `volume`: total_volume (Dict{String, Float64})
- `mcap_change_24h`: market_cap_change_percentage_24h_usd"
function globaldata()
    data = get(ApiPaths.glob)["data"]
    (;
        volume=convert(Dict{String,Float64}, data["total_volume"]),
        mcap_change_24h=Float64(data["market_cap_change_percentage_24h_usd"]),
        date=DateTime(data["updated_at"])
    )
end

@doc """ 24h trending top 7 coins.

 """
function trending()
    begin
        json = get(ApiPaths.trending)
        Dict(
            begin
                itm = item["item"]
                itm = (;
                    id=convert(String, itm["id"]),
                    price_btc=convert(Float64, itm["price_btc"]),
                    slug=convert(String, itm["slug"]),
                    sym=convert(String, itm["symbol"])
                )
                itm.id => itm
            end for item in json["coins"]
        )
    end
end

@doc """ Returns all unexpired derivative contracts.

Contracts are grouped by exchange, the id being the slugified exchange name.
"""
function derivatives()
    begin
        json = get(ApiPaths.derivatives, ("include_tickers" => "unexpired",))
        data = Dict{String,Any}()
        for d in json
            mkt = lowercase(replace(d["market"], r"[[:punct:]]" => "", r" " => "_"))
            mkt ∉ keys(data) && (data[mkt] = Dict{String,Any}[])
            push!(data[mkt], convert(Dict{String,Any}, d))
        end
        data
    end
end

drv_exchanges = Dict{String,String}()
@doc "Returns the list of all exchange ids."
function loadderivatives!()
    begin
        isempty(drv_exchanges) && begin
            path = (ApiPaths.derivatives_exchanges, "/list")
            json = get(join(path))
            for v in json
                drv_exchanges[v["id"]] = v["name"]
            end
        end
        drv_exchanges
    end
end

@doc "Fetch derivatives from specified exchange.

Returns a Dict{`Derivative`, Dict}."
function derivatives_from(id)
    @assert id ∈ keys(drv_exchanges) "Not a valid exchange id (call `loadderivatives!` to fetch ids)."
    path = (ApiPaths.derivatives_exchanges, "/", id)
    json = get(join(path), ("include_tickers" => "unexpired",))
    Dict(
        begin
            v = convert(Dict{String,Any}, t)
            perpetual(
                convert(String, v["symbol"]),
                convert(String, v["base"]),
                convert(String, v["target"]),
            ) => v
        end for t in json["tickers"]
    )
end

exchanges = Dict{String,String}()
function loadexchanges!()
    if isempty(exchanges)
        json = get(ApiPaths.exchanges)
        for e in json
            @show e["id"]
            exchanges[e["id"]] = e["name"]
        end
    end
    exchanges
end
@doc """ Fetches top 100 tickers from exchange.

Returns a Dict{Asset, Dict}
"""
function tickers_from(exc_id)
    @assert exc_id ∈ keys(exchanges) "Exchange id not found, call `loadexchanges!` to fetch ids."
    path = (ApiPaths.exchanges, "/", exc_id)
    json = get(join(path))
    Dict(
        Asset(SubString(""), t["base"], t["target"]) => convert(Dict{String,Any}, t) for
        t in json["tickers"] if _is_valid(t)
    )
end

end
