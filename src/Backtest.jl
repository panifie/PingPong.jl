module Backtest


using Conda
using PyCall
using Zarr
using Dates: unix2datetime
using TimeSeries: TimeArray
using TimeSeriesResampler: resample
using JSON
using Format
using DataFrames
using StatsBase: mean, iqr
using Dates
using DataStructures: CircularBuffer
using Indicators; ind = Indicators

include("zarr_utils.jl")
include("data.jl")

const ccxt = Ref(pyimport("os"))
const ccxt_loaded = Ref(false)
const OHLCV_COLUMNS = [:timestamp, :open, :high, :low, :close, :volume]
const OHLCV_COLUMNS_TS = setdiff(OHLCV_COLUMNS, [:timestamp])

function init_ccxt()
    if !ccxt_loaded[]
        try
            ccxt[] = pyimport("ccxt")
            ccxt_loaded[] = true
        catch
            Conda.pip("install", "ccxt")
            ccxt[] = pyimport("ccxt")
        end
    end
end

function get_exchange(name::Symbol, params=nothing)
    init_ccxt()
    exc_cls = getproperty(ccxt[], name)
    exc = isnothing(params) ? exc_cls() : exc_cls(params)
    exc.loadMarkets()
    exc
end

function get_markets(exc ;quot="USDT", sep='/')
    markets = exc.markets
    f_markets = Dict()
    for (p, info) in markets
        _, pquot = split(p, sep)
        # NOTE: split returns a substring
        pquot == quot && begin f_markets[p] = info end
    end
    f_markets
end

const leverage_pair_rgx = r"(?:(?:BULL)|(?:BEAR)|(?:[0-9]+L)|([0-9]+S)|(?:UP)|(?:DOWN)|(?:[0-9]+LONG)|(?:[0-9+]SHORT))[\/\-\_\.]"

@inline function sanitize_pair(pair::AbstractString)
    replace(pair, r"\.|\/|\-" => "_")
end

function is_leveraged_pair(pair)
    !isnothing(match(leverage_pair_rgx, pair))
end

function get_pairlist(exc, quot="")
    pairlist = []
    local push_fun
    if isempty(quot)
        push_fun = (p, k, v) -> push!(p, (k, v))
    else
        push_fun = (p, k, v) -> v["quoteId"] === quot && push!(p, (k, v))
    end
    for (k, v) in exc.markets
        if is_leveraged_pair(k)
            continue
        else
            push_fun(pairlist, k, v)
        end
    end
    pairlist
end

@inline function pair_key(exc_name, pair, timeframe; kind="ohlcv")
    "$exc_name/$(sanitize_pair(pair))/$kind/tf_$timeframe"
end

function pair_data(zi::ZarrInstance, exc_name, pair, timeframe; mode="w")
    key = pair_key(exc_name, pair, timeframe)
    if Zarr.is_zarray(zi.store, key)
        zopen(zi.store, mode; path=key)
    else
        zcreate(Array{Float64, 6}, zi.group, key)
    end
end

function is_timeframe_supported(timeframe, exc)
    timeframe ∈ keys(exc.timeframes)
end

function combine_data(prev, data)
    df1 = DataFrame(prev, OHLCV_COLUMNS)
    df2 = DataFrame(data, OHLCV_COLUMNS)
    combinerows(df1, df2; idx=:timestamp)
end

function fetch_pair(exc, zi, pair, timeframe; from="", to="", params=Dict())
    from = timefloat(from)
    if to === ""
        to = Dates.now() |> timefloat
    else
        to = timefloat(to)
        from > to && @error "End date ($(to |> dt)) must be higher than start date ($(from |> dt))."
    end
    _fetch_pair(exc, zi, pair, timeframe; from, to, params)
end

using ElasticArrays

function _fetch_pair(exc, zi, pair, timeframe; from::AbstractFloat, to::AbstractFloat, params)
    @astd
    sleep_t = div(exc.timeout, 1e4)
    pair ∉ keys(exc.markets) && throw("Pair not in exchange markets.")
    data = DataFrame([Float64[] for _ in OHLCV_COLUMNS], OHLCV_COLUMNS)
    local cur_ts
    if from === 0.0
        # fetch the first available candles using a long (1w) timeframe
        since = _fetch_with_delay(exc, pair, "1w";)[begin, 1]
        @show dt(since)
    else
        append!(data, _fetch_with_delay(exc, pair, timeframe; since=from, params))
        size(data, 1) === 0 && throw("Couldn't fetch candles for $pair from $(exc.name), too long dates? $(dt(from)).")
        since = data[end, 1]
    end
    while since < to
        sleep(sleep_t)
        fetched = _fetch_with_delay(exc, pair, timeframe; since, params)
        append!(data, DataFrame(fetched, OHLCV_COLUMNS))
        # fetched = exc.fetchOHLCV(pair, timeframe; since, params)
        since === data[end, 1] && break
        since = data[end, 1]
        @debug "Downloaded candles for pair $pair up to $since from $(exc.name)."
    end
    return data
    # convert(Matrix{Float64}, data)
end

using PyCall: PyError
function _fetch_with_delay(exc, pair, timeframe; since=nothing, params=Dict(), sleep_t=0)
    try
        return exc.fetchOHLCV(pair, timeframe; since, params)
    catch e
        if e isa PyError && !isnothing(match(r"429([0]+)?", string(e.val)))
            sleep(sleep_t)
            sleep_t = (sleep_t + 1) * 2
            _fetch_with_delay(exc,pair, timeframe; since, params, sleep_t)
        else
            rethrow(e)
        end
    end
end

function fetch_all_pairs(exc, zi::ZarrInstance, timeframe::AbstractString, qc="USDT"; limit=1500)
    exc_name = exc.name
    if !is_timeframe_supported(timeframe, exc)
        @error "Timeframe $timeframe not supported by exchange $exc_name"
    end
    for (pair, info) in get_pairlist(exc, qc)
        # data = pair_data(zi, exc_name, pair, timeframe)
        newdata = convert(Matrix{Float64}, exc.fetchOHLCV(pair, timeframe; limit))
        return newdata
        za, zg = zsave(zi, newdata, pair, timeframe; merge_fun=combine_data)
        # append!(data, newdata)
        break
    end
end

@doc "Convert ccxt OHLCV data to a timearray/dataframe."
function to_df(data; fromta=false)
    # ccxt timestamps in milliseconds
    dates = unix2datetime.(@view(data[:, 1]) / 1e3)
    fromta && return TimeArray(dates, @view(data[:, 2:end]), OHLCV_COLUMNS_TS) |> DataFrame
    DataFrame(:timestamp => dates,
              [OHLCV_COLUMNS_TS[n] => @view(data[:, n+1])
               for n in 1:length(OHLCV_COLUMNS_TS)]...)
end

function fetch_ohlcv(exc, pair; timeframe="1m", limit=1000)
    ohlcv = exc.fetchOHLCV(pair, timeframe=timeframe, limit=limit)
    to_df(ohlcv)
end

using TimeSeriesResampler: dt_grouper, timestamp, TimeArrayResampler, GroupBy
using TimeSeries: collapse

function firstrs(resampler::TimeArrayResampler)
    ta = resampler.ta
    f_group = dt_grouper(resampler.tf, eltype(timestamp(resampler.ta)))
    collapse(ta, f_group, first, first)
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


@doc "Print a number."
function printn(n, cur="USDT"; precision=2, commas=true, kwargs...)
    println(format(n; precision, commas, kwargs...), " ", cur)
end


function in_repl()
    exc = get_exchange(:kucoin)
    exckeys!(exc, values(Backtest.kucoin_keys())...)
    zi = ZarrInstance()
    exc, zi
end

export printn, obimbalance

end # module
