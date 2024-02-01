module CoinMarketCap
using Watchers
using HTTP
using URIs
using LazyJSON
using ..Misc: Config, config, queryfromstruct
using ..Lang: Option

const API_HEADER = "X-CMC_PRO_API_KEY"
const API_URL = "https://pro-api.coinmarketcap.com"
const API_KEY_CONFIG = "coinmarketcap_apikey"
const API_KEY = Ref("")
const API_HEADERS = ["Accept-Encoding" => "deflate,gzip", "Accept" => "application/json"]

@doc """Sets coinmarketcap api key.

- from env var `PINGPONG_CMC_APIKEY`
- or from config key $(API_KEY_CONFIG)
"""
function setapikey!(from_env=false, config_path=joinpath(pwd(), "user", "secrets.toml"))
    apikey = if from_env
        Base.get(ENV, "PINGPONG_CMC_APIKEY", "")
    else
        cfg = Config(:default, config_path)
        @info cfg.attrs
        @assert API_KEY_CONFIG ∈ keys(cfg.attrs) "$API_KEY_CONFIG not found in secrets."
        cfg.attrs[API_KEY_CONFIG]
    end
    keepat!(API_HEADERS, (x -> x[1] != API_HEADER).(API_HEADERS))
    push!(API_HEADERS, API_HEADER => apikey)
    nothing
end

const ApiPaths = (;
    info="/v1/key/info",
    map="/v1/cryptocurrency/map",
    metadata="/v2/cryptocurrency/info",
    listings="/v1/cryptocurrency/listings/latest",
    quotes="/v2/cryptocurrency/quotes/latest",
    global_quotes="/v1/global-metrics/quotes/latest",
    crypto_cat="/v1/cryptocurrency/category",
    categories="/v1/cryptocurrency/categories",
)

check_error(json) =
    let code = json["status"]["error_code"]
        @assert code == 0 "CoinMarketCap response error ($code)!"
    end

function get(path::T where {T}, query=nothing)
    json = LazyJSON.value(HTTP.get(absuri(path, API_URL); query, headers=API_HEADERS).body)
    check_error(json)
    json
end

@enum SortBy begin
    date_added
    market_cap
    num_market_pairs
    volume_24h
    percent_change_1h
    percent_change_24h
    percent_change_7d
    volume_7d
    volume_30d
end

@enum SortDir asc desc

@kwdef struct Params
    start = 1
    limit = 100
    market_cap_min::Option{Int} = nothing
    volume_24h_min::Option{Int} = nothing
    percent_change_24h_min::Option{Int} = nothing
    sort::SortBy = volume_24h
    sort_dir::SortDir = desc
end

@doc "Call `quotes` to get data for a specific list of currencies.

Passing values of type `Symbol` will use the `symbol` parameter, while
`String` will use the `slug` parameter.
"
function quotes(syms::AbstractArray{String})
    get(ApiPaths.quotes, "slug" => join(syms, ","))
end
quotes(syms::AbstractArray{Symbol}) = get(ApiPaths.quotes, "symbol" => join(syms, ","))

@doc "Fetch all coin listings."
function listings(quot="USD", as_json=false; kwargs...)
    query = queryfromstruct(Params; kwargs...)
    json = get(ApiPaths.listings, query)
    if as_json
        json
    else
        convert(Vector{Dict{String,Any}}, json["data"])
    end
end

@doc "Fetch remaining credits."
function credits()
    json = get(ApiPaths.info)
    usg = json["data"]["usage"]
    (;
        minute=usg["current_minute"]["requests_left"],
        day=usg["current_day"]["credits_left"],
        month=usg["current_month"]["credits_left"],
    )
end

usdquote(entry) = entry["quote"]["USD"]
usdquotes(entries) = usdquote.(entries)
usdvol(entry::AbstractDict) = Float64(usdquote(entry)["volume_24h"])
usdvol(data::AbstractVector) = usdvol.(data)
usdprice(entry::AbstractDict) = Float64(usdquote(entry)["price"])
usdprice(data::AbstractVector) = usdprice.(data)

export setapikey!, quotes, listings, credits, SortBy

end
