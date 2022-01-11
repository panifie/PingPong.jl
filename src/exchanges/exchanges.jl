module Exchanges

using Dates: Period, unix2datetime, Minute
using DataFrames: DataFrame
using ExpiringCaches: Cache
using PyCall: pyimport, PyObject, @py_str, PyNULL
using Conda: pip
using JSON
using Backtest.Misc: @pymodule, @as_td, StrOrVec, DateType, OHLCV_COLUMNS, OHLCV_COLUMNS_TS, _empty_df, timefloat, fiatnames

const ccxt = PyNULL()
const exc = PyNULL()
const leverage_pair_rgx = r"(?:(?:BULL)|(?:BEAR)|(?:[0-9]+L)|([0-9]+S)|(?:UP)|(?:DOWN)|(?:[0-9]+LONG)|(?:[0-9+]SHORT))[\/\-\_\.]"
const tickers_cache = Cache{Int, T where T <: AbstractDict}(Minute(100))

macro exchange!(name)
    exc_var = esc(name)
    exc_str = lowercase(string(name))
    exc_istr = string(name)
    quote
        exc_sym = Symbol($exc_istr)
        $exc_var = (py"$(exc) is not None" && lowercase(exc.name) === $exc_str) ?
            exc : (hasproperty($(__module__), exc_sym) ?
            getproperty($(__module__), exc_sym) : getexchange(exc_sym))
    end
end

function getexchange(name::Symbol, params=nothing)
    @pymodule ccxt
    exc_cls = getproperty(ccxt, name)
    exc = isnothing(params) ? exc_cls() : exc_cls(params)
    exc.loadMarkets()
    exc
end

function setexchange!(name, args...; kwargs...)
    copy!(exc, getexchange(name, args...; kwargs...))
    keysym = Symbol("$(name)_keys")
    if hasproperty(@__MODULE__, keysym)
        kf = getproperty(@__MODULE__, keysym)
        @assert kf isa Function "Can't set exchange keys."
        exckeys!(exc, values(kf())...)
    end
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
        isempty(tickers_cache) || begin $tickers = first(tickers_cache)[2] end
        @assert $(exc).has["fetchTickers"] "Exchange doesn't provide tickers list."
        tickers_cache[0] = $tickers = $(exc).fetchTickers()
    end
end

function get_markets(exc; min_volume=10e4, quot="USDT", sep='/')
    @assert exc.has["fetchTickers"] "Exchange doesn't provide tickers list."
    markets = exc.markets
    tickers = exc.fetchTickers()
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
    get_pairlist(exc, "", options["quote"]; kwargs...)
end

function get_pairlist(quot::AbstractString, min_vol::AbstractFloat=10e4; kwargs...)
    get_pairlist(exc, quot, min_vol; kwargs...)
end

function get_pairlist(exc, quot::AbstractString, min_vol::AbstractFloat=10e4; skip_fiat=true, margin=false)::AbstractDict
    @tickers
    pairlist = []
    local push_fun
    if isempty(quot)
        push_fun = (p, k, v) -> push!(p, (k, v))
    else
        push_fun = (p, k, v) -> v["quoteId"] === quot && push!(p, (k, v))
    end
    for (k, v) in exc.markets
        if is_leveraged_pair(k) ||
            tickers[k]["quoteVolume"] <= min_vol ||
            (skip_fiat && is_fiat_pair(k)) ||
            (margin && !v["margin"])
            continue
        else
            push_fun(pairlist, k, v)
        end
    end
    isempty(quot) && return pairlist
    Dict(pairlist)
end

function is_timeframe_supported(timeframe, exc)
    timeframe ∈ keys(exc.timeframes)
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
