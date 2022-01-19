module Exchanges

import Base.getproperty
using Dates: Period, unix2datetime, Minute, Day, now
using DataFrames: DataFrame
using TimeToLive: TTL
using PythonCall: Py, @py, pynew, pyexec, pycopy!, pytype, pyissubclass, pyisnull, PyDict, pyconvert, pydict
using Conda: pip
using JSON
using Backtest.Misc: @pymodule, @as_td, StrOrVec, DateType, OHLCV_COLUMNS, OHLCV_COLUMNS_TS, _empty_df, timefloat, fiatnames, default_data_path, dt
using Serialization: serialize, deserialize

const ccxt = pynew()
const exclock = ReentrantLock()
const leverage_pair_rgx = r"(?:(?:BULL)|(?:BEAR)|(?:[0-9]+L)|([0-9]+S)|(?:UP)|(?:DOWN)|(?:[0-9]+LONG)|(?:[0-9+]SHORT))[\/\-\_\.]"
const tickers_cache = TTL{String, T where T <: AbstractDict}(Minute(100))

OptionsDict = Dict{String, Dict{String, Any}}

mutable struct Exchange
    py::Py
    isset::Bool
    timeframes::Set{String}
    name::String
    markets::OptionsDict
    Exchange(x::Py) = if pyisnull(x)
        new(x, false, Set(), "", OptionsDict())
    elseif pyissubclass(pytype(x), ccxt.Exchange)
        new(x, true, Set(x.timeframes), string(x.name), OptionsDict(PyDict(exc.markets)))
    else
        throw("Object provided to exchange constructor is not an ccxt exchange or None.")
    end
    Exchange(x::Symbol) = begin
        e = getexchange(x)
        new(e, true, e.timeframes, string(e.name), OptionsDict(PyDict(e.markets)))
    end
end

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
    mkpath(joinpath(default_data_path, "markets"))
end

macro exchange!(name)
    exc_var = esc(name)
    exc_str = lowercase(string(name))
    exc_istr = string(name)
    quote
        exc_sym = Symbol($exc_istr)
        $exc_var = (exc.isset[] && lowercase(exc.name) === $exc_str) ?
            exc : (hasproperty($(__module__), exc_sym) ?
            getproperty($(__module__), exc_sym) : getexchange(exc_sym))
    end
end

function isfileyounger(f::AbstractString, p::Period)
    isfile(f) && dt(stat(f).mtime) < now() - p
end

function loadmarkets!(exc; cache=true, agemax=Day(1))
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
        serialize(mkt, pd)
        merge!(exc.markets, pd)
    end
    nothing
end

function getexchange(name::Symbol, params=nothing; markets=true)
    @debug "Loading CCXT..."
    @pymodule ccxt
    @debug "Instantiating Exchange $name..."
    exc_cls = getproperty(ccxt, name)
    exc = isnothing(params) ? exc_cls() : exc_cls(params)
    @debug "Loading Markets..."
    markets && loadmarkets!(exc)
    @debug "Loaded $(length(exc.markets))."
    exc
end

function setexchange!(name::Symbol, args...; kwargs...)
    setexchange!(exc, name, args...; kwargs...)
end

function setexchange!(exc::Exchange, name::Symbol, args...; kwargs...)
    pycopy!(exc.py, getexchange(name, args...; kwargs...))
    exc.isset = true
    empty!(exc.timeframes)
    push!(exc.timeframes, pyconvert(Vector{String}, exc.py.timeframes)...)
    exc.name = string(exc.py.name)

    keysym = Symbol("$(name)_keys")
    if hasproperty(@__MODULE__, keysym)
        @debug "Setting exchange keys..."
        kf = getproperty(@__MODULE__, keysym)
        @assert kf isa Function "Can't set exchange keys."
        exckeys!(exc, values(kf())...)
    end
    exc
end

@doc "Convert ccxt OHLCV data to a timearray/dataframe."
function to_df(data; fromta=false)
    # ccxt timestamps in milliseconds
    dates = unix2datetime.(@view(data[:, 1]) / 1e3)
    fromta && return TimeArray(dates, @view(data[:, 2:end]), OHLCV_COLUMNS_TS) |> x-> DataFrame(x; copycols=false)
    DataFrame(:timestamp => dates,
              [OHLCV_COLUMNS_TS[n] => @view(data[:, n + 1])
               for n in 1:length(OHLCV_COLUMNS_TS)]...; copycols=false)
end

macro as_df(v)
    quote
        to_df($(esc(v)))
    end
end

macro tickers()
    exc = esc(:exc)
    tickers = esc(:tickers)
    quote
        begin
            local $tickers
            let nm = $exc.name
                if nm ∉ keys(tickers_cache)
                    @assert Bool($(exc).has["fetchTickers"]) "Exchange doesn't provide tickers list."
                    tickers_cache[nm] = $tickers = pyconvert(Dict{String, Dict{String, Any}}, $(exc).fetchTickers())
                else
                    $tickers = tickers_cache[nm]
                end
            end
        end
    end
end

function get_markets(exc; min_volume=10e4, quot="USDT", sep='/')
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

function is_fiat_pair(pair)
    p = split(pair, r"\/|\-|\_|\.")
    p[1] ∈ fiatnames && p[2] ∈ fiatnames
end

function get_pairlist(; kwargs...)
    get_pairlist(exc, options["quote"], options["min_vol"]::T where T<: AbstractFloat; kwargs...)
end

function get_pairlist(quot::AbstractString, min_vol::AbstractFloat=10e4; kwargs...)
    get_pairlist(exc, quot, min_vol; kwargs...)
end

function get_pairlist(exc, quot::String, min_vol::Float64=10e4; skip_fiat=true, margin=false)::Dict
    @tickers
    pairlist = []
    local push_fun
    if isempty(quot)
        push_fun = (p, k, v) -> push!(p, (k, v))
    else
        push_fun = (p, k, v) -> string(v["quoteId"]) === quot && push!(p, (k, v))
    end
    for (k, v) in exc.markets
        if is_leveraged_pair(k) ||
            tickers[k]["quoteVolume"] <= min_vol ||
            (skip_fiat && is_fiat_pair(k)) ||
            (margin && !Bool(v["margin"]))
            continue
        else
            push_fun(pairlist, k, v)
        end
    end
    isempty(quot) && return pairlist
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

function kucoin_keys()
    cfg = Dict()
    open(joinpath(ENV["HOME"], "dev", "Backtest.jl", "cfg", "kucoin.json")) do f
        cfg = JSON.parse(f)
    end
        key = cfg["apiKey"]
    secret = cfg["secret"]
    password = cfg["password"]
    Dict("key" => key, "secret" => secret, "pass" => password)
end

function poloniex_update(;timeframe="15m", quot="USDT", min_vol=10e4)
    @exchange! poloniex
    fetch_pairs(poloniex, timeframe; qc=quot, zi, update=true)
    prl = get_pairlist(poloniex, quot, min_vol)
    load_pairs(zi, exc, prl, timeframe)
end

macro excfilter(exc_name)
    bt = @__MODULE__
    quote
        local trg
        @info "timeframe: $(options["timeframe"]), window: $(options["window"]), quote: $(options["quote"]), min_vol: $(options["min_vol"])"
	    @exchange! $exc_name
        data = (get_pairlist(options["quote"]) |> (x -> load_pairs(zi, $exc_name, x, options["timeframe"])))
        flt = $bt.filter(x -> $(bt).slopeangle(x; window=options["window"]), data, options["min_slope"], options["max_slope"])
        trg = [p[2].name for p in flt]
        results[lowercase($(exc_name).name)] = (;trg, flt, data)
        trg
    end
end

function fetch!()
    @eval include(joinpath(dirname(@__FILE__), "fetch.jl"))
end

export exc, @excfilter, exchange!, setexchange!, exckeys!

end
