import Data: load_ohlcv, save_ohlcv
using Data: zi, PairData
using Misc: config

load_ohlcv(timeframe::AbstractString) =
    load_ohlcv(get_pairlist(config.qc; as_vec = true, margin = config.margin), timeframe)

load_ohlcv(exc::Exchange, timeframe::AbstractString) = load_ohlcv(zi, exc, pairs, timeframe)
load_ohlcv(exc::Exchange, pair::AbstractString, timeframe) =
    load_ohlcv(zi, exc, [pair], timeframe)
load_ohlcv(
    exc::Exchange,
    pairs::Union{AbstractArray,AbstractDict},
    timeframe::AbstractString,
) = load_ohlcv(zi, exc, pairs, timeframe)
@doc "Load all pairs from exchange according to config quote currency and timeframe."
load_ohlcv() = load_ohlcv(get_pairlist(config.qc), convert(String, config.timeframe))
load_ohlcv(zi, exc, pairs::AbstractDict, timeframe) =
    load_ohlcv(zi, exc, keys(pairs), timeframe)
load_ohlcv(pairs::Union{AbstractArray,AbstractDict}, timeframe::AbstractString) =
    load_ohlcv(zi, exc, pairs, timeframe)

save_ohlcv(exc::Exchange, args...; kwargs...) = begin
    save_ohlcv(zi[], exc.name, args...; kwargs...)
end

@doc "Updates pair data of the globally set exchange."
function save_ohlcv(pair, timeframe, data; kwargs...)
    @assert pair ∈ keys(exc.markets) "Mismatching global exchange instance and pair. Pair not in exchange markets."
    save_ohlcv(zi[], exc.name, pair, timeframe, data; kwargs...)
end


export load_ohlcv, save_ohlcv
