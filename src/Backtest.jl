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

function download_pairs(exc, zi::ZarrInstance, timeframe::AbstractString, qc="USDT"; limit=2880)
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
function to_df(data)
    # ccxt timestamps in milliseconds
    dates = unix2datetime.(data[:, 1] / 1e3)
    TimeArray(dates, data[:, 2:end], [:open, :high, :low, :close, :volume]) |>
        DataFrame
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

function save_pair(zi::ZarrInstance, pair, label, data)
    if pair ∈ zi.group.groups
        zg = zi.group[pair]
    else
        zg = zgroup(zi.group, pair)
    end
    if label ∈ zg.arrays
        old = zg[label][:]
        merge!(old, data)
        zg[label] = old
    else
        za = zcreate(zg, label)
        za[:] = data
    end
end

function pair_data(zi, pair, timeframe="1m", from="", to="")
    @zkey
    za = zopen(zi.store, "w"; path=key)
end

export printn, obimbalance

end # module
