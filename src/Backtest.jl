module Backtest

using Strategems
using Conda
using PyCall
using Zarr
using Dates: unix2datetime
using TimeSeries: TimeArray
using TimeSeriesResampler: resample
using JSON

const ccxt = Ref(pyimport("os"))
const default_data_path = get(ENV, "XDG_CACHE_DIR", "$(joinpath(ENV["HOME"], ".cache", "Backtest.jl", "data"))")
const ccxt_loaded = Ref(false)

struct ZarrInstance
    path::AbstractString
    store::DirectoryStore
    group::ZGroup
    function ZarrInstance(data_path=default_data_path)
        ds = DirectoryStore(data_path)
        if !Zarr.is_zgroup(ds, "")
            zgroup(ds)
        end
        g = zopen(ds, "w")
        new(data_path, ds, g)
    end
end

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

function get_pairlist(exc)
    pairlist = []
    for (k, v) in exc.markets
        if is_leveraged_pair(k)
            continue
        else
            push!(pairlist, (k, v))
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

function download_pairs(exc, zi::ZarrInstance, timeframe::AbstractString)
    exc_name = exc.name
    if !is_timeframe_supported(timeframe, exc)
        @error "Timeframe $timeframe not supported by exchange $exc_name"
    end
    for (pair, info) in get_pairlist(exc)
        data = pair_data(zi, exc_name, pair, timeframe)
        newdata = exc.fetchOHLCV(pair, timeframe; limit=2880)
        return newdata
        # append!(data, newdata)
        break
    end
end

@doc "Convert ccxt OHLCV data to a timearray"
function to_timearray(data)
    # ccxt timestamps in milliseconds
    dates = unix2datetime.(data[:, 1] / 1e3)
    TimeArray(dates, data[:, 2:end], [:open, :high, :low, :close, :volume])
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

end # module
