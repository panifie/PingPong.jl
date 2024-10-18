module CoinGecko
using HTTP
using URIs
using JSON3
using ..Watchers
using ..Lang: @kget!, Option
using ..Misc
using ..Misc.TimeToLive
using ..TimeTicks
using ..TimeTicks: timestamp
using ..Fetch.Instruments
using ..Watchers: jsontodict
using .Instruments.Derivatives

const API_URL = "https://api.coingecko.com"
const API_HEADERS = ["Accept-Encoding" => "deflate,gzip", "Accept" => "application/json"]
const ApiPaths = (;
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
    glob="/api/v3/global",
)
const DEFAULT_CUR = "usd"

const last_query = Ref(DateTime(0))
const RATE_LIMIT = Ref(Millisecond(3 * 1000))
const STATUS = Ref{Int}(0)
const RETRY = Ref(false)
@doc "Allows only 1 query every $(RATE_LIMIT[]) seconds."
ratelimit() = sleep(max(Second(0), (last_query[] - now()) + RATE_LIMIT[]))

function get(path, query=nothing, inc=500)
    ratelimit()
    resp = try
        HTTP.get(absuri(path, API_URL); query, headers=API_HEADERS)
    catch e
        e
    end
    last_query[] = now()
    if hasproperty(resp, :status)
        STATUS[] = resp.status
        if resp.status == 429 && RETRY[]
            @warn "coingecko: 429" path
            sleep(RATE_LIMIT[] + Millisecond(inc))
            return get(path, query, inc * 2)
        else
            @assert resp.status == 200 resp
        end
        setglobal!(Main, :v, resp.body)
        json = JSON3.read(resp.body)
        return json
    else
        throw(resp)
    end
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
    return jsontodict(json)
end

const currencies = Set{String}()
vs_currencies() =
    if length(currencies) > 0
        currencies
    else
        json = get(ApiPaths.simple_vs)
        for el in json
            push!(currencies, el)
        end
        currencies
    end

const coins = safettl(Nothing, Dict{String,String}, Minute(60))
const coins_syms = Dict{String,Vector{SubString}}()
@doc "Load all coins symbols."
loadcoins!() = @kget! coins nothing begin
    json = get(ApiPaths.coins_list)
    @assert !isnothing(json)
    data = Dict{String,String}()
    for d in json
        id = d["id"]
        sym = d["symbol"]
        data[id] = sym
        ls = lowercase(sym)
        push!(@kget!(coins_syms, ls, SubString[]), id)
    end
    data
end

@doc "Get all coingecko item id matching by its symbol."
function idbysym(sym, ::Bool)
    loadcoins!()
    @something Base.get(coins_syms, lowercase(string(sym)), nothing) []
end
@doc "Get the first coingecko item id by its symbol."
idbysym(sym) = begin
    match = idbysym(sym, true)
    @assert !isempty(match) "$sym not a valid coingecko id."
    first(match)
end

tickerbyid(id) = begin
    loadcoins!()
    for (ticker, ids) in coins_syms
        idx = findfirst(ids) do i
            i == id
        end
        if !isnothing(idx)
            return ticker
        end
    end
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

const oneHour = "1h"
const oneDay = "24h"
const oneWeek = "7d"
const twoWeeks = "14d"
const oneMonth = "30d"
const sixMonths = "200d"
const oneYear = "1y"

@kwdef struct Params
    vs_currency = DEFAULT_CUR
    ids::Option{Vector{String}} = nothing
    order = volume_desc
    per_page = 100 # max 250
    page = 1
    price_change_percentage = [oneHour, oneDay, oneWeek, oneMonth, sixMonths]
end

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
        price = Float64(data["current_price"][cur])
        volume = Float64(data["total_volume"][cur])
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
    return (; dates, prices, volume)
end

@doc """Get `close` price and volume for symbol `id` for specified number of days.
!!! info "days=\"max\""
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

!!! warning "From coingecko:"
    Data granularity is automatic (cannot be adjusted)
    - 1 day from current time = 5 minute interval data
    - 1 - 90 days from current time = hourly data
    - above 90 days from current time = daily data (00:00 UTC)

 """
function coinschart_range(id::AbstractString; from, to=now(), vs=DEFAULT_CUR)
    begin
        path = (ApiPaths.coins_id, "/", id, "/market_chart/range")
        json = get(
            join(path),
            (
                "from" => timestamp(from, Val(:trunc)),
                "to" => timestamp(to, Val(:trunc)),
                "vs_currency" => vs,
            ),
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
    return (;
        volume=jsontodict(data["total_volume"], to=Dict{String,Float64}),
        mcap_change_24h=Float64(data["market_cap_change_percentage_24h_usd"]),
        date=unix2datetime(data["updated_at"]),
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
                    sym=convert(String, itm["symbol"]),
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
            push!(data[mkt], jsontodict(d))
        end
        data
    end
end

const drv_exchanges = Dict{String,String}()
@doc "Returns the list of all exchange ids."
function loadderivatives!()
    isempty(drv_exchanges) && begin
        path = (ApiPaths.derivatives_exchanges, "/list")
        json = get(join(path))
        for v in json
            drv_exchanges[v["id"]] = v["name"]
        end
    end
    return drv_exchanges
end

function check_drv_exchange(id)
    @assert id ∈ keys(loadderivatives!()) "Not a valid exchange id (call `loadderivatives!` to fetch ids)."
end

@doc "Fetch derivatives from specified exchange.

Returns a Dict{`Derivative`, Dict}."
function derivatives_from(id)
    check_drv_exchange(id)
    path = (ApiPaths.derivatives_exchanges, "/", id)
    json = get(join(path), ("include_tickers" => "unexpired",))
    return Dict(
        begin
            v = Dict{String,Any}(string(k) => v for (k, v) in t)
            perpetual(
                convert(String, v["symbol"]),
                convert(String, v["base"]),
                convert(String, v["target"]),
            ) => v
        end for t in json["tickers"]
    )
end

const exchanges = Dict{String,String}()
function loadexchanges!()
    if isempty(exchanges)
        json = get(ApiPaths.exchanges)
        for e in json
            exchanges[e["id"]] = e["name"]
        end
    end
    return exchanges
end
@doc """ Fetches top 100 tickers from exchange.

Returns a Dict{Asset, Dict}
"""
function tickers_from(exc_id)
    @assert exc_id ∈ keys(exchanges) "Exchange id not found, call `loadexchanges!` to fetch ids."
    path = (ApiPaths.exchanges, "/", exc_id)
    json = get(join(path))
    return Dict(
        Asset(SubString(""), t["base"], t["target"]) => jsontodict(t) for
        t in json["tickers"] if _is_valid(t)
    )
end

end
