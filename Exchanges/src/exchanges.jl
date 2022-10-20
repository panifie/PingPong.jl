
import Base.getproperty

using DataFrames: DataFrame
using Dates: Day, Minute, Period, now, unix2datetime
using JSON
using Misc: @as_td, @pymodule, DateType, Exchange, OHLCV_COLUMNS, OHLCV_COLUMNS_TS,
    OptionsDict, StrOrVec, _empty_df, default_data_path, dt, fiatnames, futures_exchange,
    timefloat
using PythonCall: @py, Py, PyDict, PyException, pyconvert, pycopy!, pydict, pydir, pyexec,
    pygetattr, pyimport, pyisnone, pyisnull, pyissubclass, pynew, pytype
using Serialization: deserialize, serialize
using TimeToLive: TTL

const ccxt = pynew()
const ccxt_errors = Set{String}()
const exclock = ReentrantLock()
const leverage_pair_rgx =
    r"(?:(?:BULL)|(?:BEAR)|(?:[0-9]+L)|(?:[0-9]+S)|(?:UP)|(?:DOWN)|(?:[0-9]+LONG)|(?:[0-9+]SHORT))([\/\-\_\.])"
const tickers_cache = TTL{String,T where T<:AbstractDict}(Minute(100))

const exc = Exchange(pynew())

function getproperty(e::Exchange, k::Symbol)
    if hasfield(Exchange, k)
        getfield(e, k)
    else
        getfield(e, :isset) || throw("Can't access non instantiated exchange object.")
        getproperty(getfield(e, :py), k)
    end
end

function __init__()
    @pymodule ccxt
    pyimport("ccxt.base.errors") |>
        pydir .|>
        string |>
        Set |>
        errors -> union(ccxt_errors, errors)
    mkpath(joinpath(default_data_path, "markets"))
end

macro exchange!(name)
    exc_var = esc(name)
    exc_str = lowercase(string(name))
    exc_istr = string(name)
    quote
        exc_sym = Symbol($exc_istr)
        $exc_var =
            (exc.isset && lowercase(exc.name) === $exc_str) ? exc :
            (
                hasproperty($(__module__), exc_sym) ? getproperty($(__module__), exc_sym) :
                Exchange(exc_sym)
            )
    end
end

function isfileyounger(f::AbstractString, p::Period)
    isfile(f) && dt(stat(f).mtime) < now() - p
end

function py_except_name(e::PyException)
    pygetattr(pytype(e), "__name__") |> string
end

function loadmarkets!(exc; cache = true, agemax = Day(1))
    mkt = joinpath(default_data_path, exc.name, "markets.jlz")
    empty!(exc.markets)
    if isfileyounger(mkt, agemax) && cache
        @debug "Loading markets from cache at $mkt."
        cached_dict = deserialize(mkt)
        merge!(exc.markets, cached_dict)
        exc.py.markets = pydict(cached_dict)
        exc.py.markets_by_id = exc.index_by(exc.py.markets, "id")
    else
        @debug "Loading markets from exchange and caching at $mkt."
        exc.loadMarkets(true)
        pd = pyconvert(OptionsDict, exc.py.markets)
        mkt |> dirname |> mkpath
        serialize(mkt, pd)
        merge!(exc.markets, pd)
    end
    nothing
end


function pyexchange(name::Symbol, params = nothing; markets = true)
    @debug "Loading CCXT..."
    @debug "Instantiating Exchange $name..."
    exc_cls = getproperty(ccxt, name)
    exc = isnothing(params) ? exc_cls() : exc_cls(params)
    exc
end

function setexchange!(name::Symbol, args...; kwargs...)
    setexchange!(exc, name, args...; kwargs...)
end


function setexchange!(exc::Exchange, name::Symbol, args...; markets = true, kwargs...)
    pycopy!(exc.py, pyexchange(name, args...; kwargs...))
    exc.isset = true
    empty!(exc.timeframes)
    tfkeys =
        pyisnone(exc.py.timeframes) ? Set{String}() :
        pyconvert(Set{String}, exc.py.timeframes.keys())
    isempty(tfkeys) || push!(exc.timeframes, tfkeys...)
    exc.name = string(exc.py.name)
    exc.sym = Symbol(exc.py.__class__.__name__)
    @debug "Loading Markets..."
    markets && loadmarkets!(exc)
    @debug "Loaded $(length(exc.markets))."

    keysym = Symbol("$(name)_keys")
    if hasproperty(@__MODULE__, keysym)
        @debug "Setting exchange keys..."
        kf = getproperty(@__MODULE__, keysym)
        @assert kf isa Function "Can't set exchange keys."
        exckeys!(exc, values(kf())...)
    end
    exc
end

function getexchange(x::Symbol)
    e = pyexchange(x) |> Exchange
    setexchange!(e, x)
end


macro as_df(v)
    quote
        to_df($(esc(v)))
    end
end

@inline function hastickers(exc::Exchange)
    Bool(exc.has["fetchTickers"])
end

@doc "Fetch and cache tickers data."
macro tickers(force = false)
    exc = esc(:exc)
    tickers = esc(:tickers)
    quote
        begin
            local $tickers
            let nm = $(exc).name
                if $force || nm ∉ keys(tickers_cache)
                    @assert hastickers($exc) "Exchange doesn't provide tickers list."
                    tickers_cache[nm] =
                        $tickers =
                            pyconvert(Dict{String,Dict{String,Any}}, $(exc).fetchTickers())
                else
                    $tickers = tickers_cache[nm]
                end
            end
        end
    end
end

function get_markets(exc; min_volume = 10e4, quot = "USDT", sep = '/')
    @assert exc.has["fetchTickers"] "Exchange doesn't provide tickers list."
    markets = exc.markets
    @tickers
    f_markets = Dict()
    for (p, info) in markets
        _, pquot = split(p, sep)
        # NOTE: split returns a substring
        if pquot == quot && tickers[p]["quoteVolume"] > min_volume
            f_markets[p] = info
        end
    end
    f_markets
end


@inline function sanitize_pair(pair::AbstractString)
    replace(pair, r"\.|\/|\-" => "_")
end

function is_leveraged_pair(pair)
    !isnothing(match(leverage_pair_rgx, pair))
end

function deleverage_pair(pair)
    dlv = replace(pair, leverage_pair_rgx => s"\1" )
    # HACK: assume that BEAR/BULL represent BTC
    pair = split(dlv, r"\/|\-|\_|\.")
    if pair[1] |> isempty
        "BTC" * dlv
    else
        dlv
    end
end

function is_fiat_pair(pair)
    p = split(pair, r"\/|\-|\_|\.")
    p[1] ∈ fiatnames && p[2] ∈ fiatnames
end

@inline function qid(v)
    k = keys(v)
    "quoteId" ∈ k ? v["quoteId"] : "quote" ∈ k ? v["quote"] : false
end

@inline is_qmatch(id, q) = lowercase(id) === q

@doc "Get price from ticker."
function aprice(t)
    something(t["average"], t["last"], t["bid"])
end

@doc "Get price ranges using tickers data from exchange."
function price_ranges(pair::AbstractString, args...; kwargs...)
    tkrs = @tickers true
    price_ranges(tkrs[pair]["last"], args...; kwargs...)
end

function qvol(t::AbstractDict)
    v1 = t["quoteVolume"]
    isnothing(v1) || return v1
    v2 = t["baseVolume"]
    isnothing(v2) || return v2 * aprice(t)
    0
end

@doc "Trims the settlement currency in futures."
@inline function as_spot_ticker(k, v)
    if "quote" ∈ keys(v)
        "$(v["base"])/$(v["quote"])"
    else
        split(k, ":")[1]
    end
end

get_pairlist(quot::AbstractString, args...; kwargs...) =
    get_pairlist(exc, quot, args...; kwargs...)
get_pairlist(
    exc::Exchange = exc,
    quot::AbstractString = config.qc,
    min_vol::T where {T<:AbstractFloat} = config.vol_min;
    kwargs...
) = get_pairlist(exc, convert(String, quot), convert(Float64, min_vol); kwargs...)

@doc """Get the exchange pairlist.
`quot`: Only choose pairs where the quot currency equals `quot`.
`min_vol`: The minimum volume of each pair.
`skip_fiat`: Ignore fiat/fiat pairs.
`margin`: Only choose pairs enabled for margin trading.
`leveraged`: If `:no` skip all pairs where the base currency matches the `leverage_pair_rgx` regex.
`as_vec`: Returns the pairlist as a Vector instead of as a Dict.
"""
function get_pairlist(
    exc::Exchange,
    quot::String,
    min_vol::Float64;
    skip_fiat = true,
    margin = config.margin,
    futures = config.futures,
    leveraged = config.leverage,
    as_vec = false
)::Union{Dict,Vector}
    # swap exchange in case of futures
    @tickers
    pairlist = []
    lquot = lowercase(quot)

    if futures
        futures_sym = get(futures_exchange, exc.sym, exc.sym)
        if futures_sym !== exc.sym
            exc = Exchange(futures_sym)
        end
    end

    tup_fun = as_vec ? (k, _) -> k : (k, v) -> k => v
    push_fun =
        isempty(quot) ? (p, k, v) -> push!(p, tup_fun(k, v)) :
        (p, k, v) -> is_qmatch(qid(v), lquot) && push!(p, tup_fun(k, v))
    # Leveraged `:from` filters the pairlist taking non leveraged pairs, IF
    # they have a leveraged counterpart
    local hasleverage
    if leveraged === :from
        if futures
            @warn "Filtering by leveraged when futures markets are enabled, are you sure?"
        end
        pairs_with_leverage = Set()
        for k in keys(exc.markets)
            dlv = deleverage_pair(k)
            if k !== dlv
                push!(pairs_with_leverage, dlv)
            end
        end
        hasleverage = (k) -> (!is_leveraged_pair(k) && k ∈ pairs_with_leverage)
    else
        hasleverage = (_) -> true
    end

    for (k, v) in exc.markets
        k = as_spot_ticker(k, v)
        lev = is_leveraged_pair(k)
        if (leveraged === :no && lev) ||
           (leveraged === :only && !lev) ||
           !hasleverage(k) ||
           (k ∈ keys(tickers) && qvol(tickers[k]) <= min_vol) ||
           (skip_fiat && is_fiat_pair(k)) ||
           (margin && !isnothing(get(v, "margin", nothing)) && !v["margin"])
            continue
        else
            push_fun(pairlist, k, v)
        end
    end
    isempty(pairlist) &&
        @warn "No pairs found, check quote currency ($quot) and min volume parameters ($min_vol)."
    isempty(quot) && return pairlist
    as_vec && return pairlist
    Dict(pairlist)
end

function is_timeframe_supported(timeframe, exc)
    timeframe ∈ exc.timeframes
end

function exckeys!(exc, key, secret, pass)
    name = uppercase(exc.name)
    exc.apiKey = key
    exc.secret = secret
    exc.password = pass
    nothing
end


include("data.jl")

export exc, @exchange!, setexchange!, getexchange, exckeys!, get_pairlist, Exchange
