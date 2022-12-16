import Data: load_pairs, save_pair
using Data: zi, PairData
using Misc: config

load_pairs(timeframe::AbstractString) =
    load_pairs(get_pairlist(config.qc; as_vec = true, margin = config.margin), timeframe)

load_pairs(exc::Exchange, timeframe::AbstractString) = load_pairs(zi, exc, pairs, timeframe)
load_pairs(exc::Exchange, pair::AbstractString, timeframe) =
    load_pairs(zi, exc, [pair], timeframe)
load_pairs(
    exc::Exchange,
    pairs::Union{AbstractArray,AbstractDict},
    timeframe::AbstractString,
) = load_pairs(zi, exc, pairs, timeframe)
@doc "Load all pairs from exchange according to config quote currency and timeframe."
load_pairs() = load_pairs(get_pairlist(config.qc), config.timeframe)
load_pairs(zi, exc, pairs::AbstractDict, timeframe) =
    load_pairs(zi, exc, keys(pairs), timeframe)
load_pairs(pairs::Union{AbstractArray,AbstractDict}, timeframe::AbstractString) =
    load_pairs(zi, exc, pairs, timeframe)

save_pair(exc::Exchange, args...; kwargs...) = begin
    save_pair(zi[], exc.name, args...; kwargs...)
end

@doc "Updates pair data of the globally set exchange."
function save_pair(pair, timeframe, data; kwargs...)
    @assert pair ∈ keys(exc.markets) "Mismatching global exchange instance and pair. Pair not in exchange markets."
    save_pair(zi[], exc.name, pair, timeframe, data; kwargs...)
end


export load_pairs, save_pair
