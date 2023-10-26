import Data: load_ohlcv, save_ohlcv
using Data: zi, PairData, ZarrInstance
using .Misc: config, Iterable

@doc "Loads all pairs for given exc/timeframe matching global `config` and `zi` (`ZarrInstance`)."
function load_ohlcv(exc::Exchange, timeframe::AbstractString; kwargs...)
    pairs = tickers(config.qc; as_vec=true, config.margin, config.min_vol)
    load_ohlcv(zi, exc, pairs, timeframe; kwargs...)
end
function load_ohlcv(exc::Exchange, pair::AbstractString, timeframe; kwargs...)
    load_ohlcv(zi, exc, (pair,), timeframe; kwargs...)
end
function load_ohlcv(exc::Exchange, pairs::Iterable, timeframe::AbstractString; kwargs...)
    pairs = pairs isa AbstractDict ? keys(pairs) : pairs
    load_ohlcv(zi, exc, pairs, timeframe; kwargs...)
end
@doc "Load given pairs from global `exc` and `ZarrInstance`."
function load_ohlcv(
    pairs::Union{AbstractArray,AbstractDict}, timeframe::AbstractString; kwargs...
)
    @assert !isempty(exc)
    load_ohlcv(zi, exc, pairs, timeframe; kwargs...)
end
@doc "Loads all pairs given timeframe matching global `exc` and `config`."
function load_ohlcv(timeframe::AbstractString; kwargs...)
    @assert !isempty(exc)
    load_ohlcv(exc, timeframe; kwargs...)
end
@doc "Load all pairs from exchange according to config quote currency and timeframe."
function load_ohlcv()
    load_ohlcv(
        tickers(config.qc; config.min_vol, as_vec=true), string(config.min_timeframe)
    )
end

function save_ohlcv(exc::Exchange, args...; kwargs...)
    save_ohlcv(zi[], exc.name, args...; kwargs...)
end

@doc "Updates pair data of the globally set exchange."
function save_ohlcv(pair, timeframe, data; kwargs...)
    @assert pair ∈ keys(exc.markets) "Mismatching global exchange instance and pair. Pair not in exchange markets."
    save_ohlcv(zi[], exc.name, pair, timeframe, data; kwargs...)
end

export load_ohlcv, save_ohlcv
