module Backtest


using Conda
using PyCall
using Zarr
using Dates:unix2datetime
using TimeSeries:TimeArray
using TimeSeriesResampler:resample
using JSON
using Format
using DataFrames
using StatsBase: mean, iqr
using Dates
using DataStructures:CircularBuffer
using Indicators; ind = Indicators
using PyCall:PyError

include("zarr_utils.jl")
include("data.jl")
include("exchanges.jl")

const ccxt = Ref(pyimport("os"))
const ccxt_loaded = Ref(false)
const OHLCV_COLUMNS = [:timestamp, :open, :high, :low, :close, :volume]
const OHLCV_COLUMNS_TS = setdiff(OHLCV_COLUMNS, [:timestamp])


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

function is_timeframe_supported(timeframe, exc)
    timeframe ∈ keys(exc.timeframes)
end

function _fetch_one_pair(exc, zi, pair, timeframe; from="", to="", params=Dict(), sleep_t=1, cleanup=true)
    from = timefloat(from)
    if to === ""
        to = Dates.now() |> timefloat
    else
        to = timefloat(to)
        from > to && @error "End date ($(to |> dt)) must be higher than start date ($(from |> dt))."
    end
    @debug "Fetching pair $pair from exchange $(exc.name) at $timeframe - from: $(from |> dt) - to: $(to |> dt)."
    data = _fetch_pair(exc, zi, pair, timeframe; from, to, params, sleep_t)
    if cleanup cleanup_ohlcv_data(data, timeframe) else data end
end

function _fetch_pair(exc, zi, pair, timeframe; from::AbstractFloat, to::AbstractFloat, params, sleep_t)
    @as_td
    pair ∉ keys(exc.markets) && throw("Pair not in exchange markets.")
    data = DataFrame([Float64[] for _ in OHLCV_COLUMNS], OHLCV_COLUMNS)
    local cur_ts
    if from === 0.0
        # fetch the first available candles using a long (1w) timeframe
        since = _fetch_with_delay(exc, pair, "1w";)[begin, 1]
    else
        append!(data, _fetch_with_delay(exc, pair, timeframe; since=from, params))
        size(data, 1) === 0 && throw("Couldn't fetch candles for $pair from $(exc.name), too long dates? $(dt(from)).")
        since = data[end, 1]
    end
    while since < to
        sleep(sleep_t)
        fetched = _fetch_with_delay(exc, pair, timeframe; since, params)
        append!(data, DataFrame(fetched, OHLCV_COLUMNS))
        since === data[end, 1] && break
        since = data[end, 1]
        @debug "Downloaded candles for pair $pair up to $(since |> dt) from $(exc.name)."
    end
    return data
end

function _fetch_with_delay(exc, pair, timeframe; since=nothing, params=Dict(), sleep_t=0)
    try
        data = exc.fetchOHLCV(pair, timeframe; since, params)
    catch e
        if e isa PyError && !isnothing(match(r"429([0]+)?", string(e.val)))
            sleep(sleep_t)
            sleep_t = (sleep_t + 1) * 2
            _fetch_with_delay(exc, pair, timeframe; since, params, sleep_t)
        else
            rethrow(e)
        end
    end
end

function fetch_pairs(exc, timeframe::AbstractString, pair::AbstractString; kwargs...)
    info = exc.markets[pair]
    fetch_pairs(exc, timeframe, [(pair, info)]; kwargs...)
end

function fetch_pairs(exc, timeframe; qc::AbstractString, kwargs...)
    pairs = get_pairlist(exc, qc)
    fetch_pairs(exc, timeframe, pairs; kwargs...)
end

struct PairData
    name::String
    tf::String # string
    data::Union{Nothing, AbstractDataFrame} # in-memory data
    z::Union{Nothing, ZArray} # reference zarray
end

PairData(;name, tf, data, z) = PairData(name, tf, data, z)

function fetch_pairs(exc, timeframe::AbstractString, pairs::AbstractArray; zi=nothing,
                     from="", to="", update=false, reset=false)
    exc_name = exc.name
    if !is_timeframe_supported(timeframe, exc)
        @error "Timeframe $timeframe not supported by exchange $exc_name"
    end
    if update
        if !isempty(from) || !isempty(to)
            @warn "Don't set the `from` or `to` date if updating existing data."
        end
        # this fetches the last date stored
        from_date = (pair) -> begin
            za, (_, stop) = load_pair(zi, exc_name, pair, timeframe; as_z=true)
            za[stop, 1]
        end
    else
        from_date = (_) -> from
    end
    data = Dict{String, PairData}()
    @info "Downloading data for $(length(pairs)) pairs."
    for (name, info) in pairs
        ohlcv =  _fetch_one_pair(exc, zi, name, timeframe; from=from_date(name), to)
        z = save_pair(zi, exc.name, name, timeframe, ohlcv; reset)
        p = PairData(;name, tf=timeframe, data=ohlcv, z)
        data[name] = p
        @info "Fetched $(size(p.data, 1)) candles for $name from $(exc.name)"
    end
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
