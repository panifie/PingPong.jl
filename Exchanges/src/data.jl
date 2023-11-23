import Data: load_ohlcv, save_ohlcv
using Data: zi, PairData, ZarrInstance
using .Misc: config, Iterable

@doc "Loads all pairs for a given exchange and timeframe, matching the global `config` and `zi` (Zarr Instance).


$(TYPEDSIGNATURES)
"
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
@doc """Load given pairs from the global `exc` (Exchange object) and `zi` (Zarr Instance).

$(TYPEDSIGNATURES)

"""
function load_ohlcv(
    pairs::Union{AbstractArray,AbstractDict}, timeframe::AbstractString; kwargs...
)
    @assert !isempty(exc)
    load_ohlcv(zi, exc, pairs, timeframe; kwargs...)
end
@doc "Loads all pairs for a given timeframe, matching the global `exc` (Exchange object) and `config`.

$(TYPEDSIGNATURES)
"
function load_ohlcv(timeframe::AbstractString; kwargs...)
    @assert !isempty(exc)
    load_ohlcv(exc, timeframe; kwargs...)
end
@doc "Load all pairs from the exchange according to the configured quote currency and timeframe.

$(TYPEDSIGNATURES)
"
function load_ohlcv()
    load_ohlcv(
        tickers(config.qc; config.min_vol, as_vec=true), string(config.min_timeframe)
    )
end

function save_ohlcv(exc::Exchange, args...; kwargs...)
    save_ohlcv(zi[], exc.name, args...; kwargs...)
end

@doc "Updates pair data of the globally set Exchange instance.

$(TYPEDSIGNATURES)
"
function save_ohlcv(pair, timeframe, data; kwargs...)
    @assert pair ∈ keys(exc.markets) "Mismatching global exchange instance and pair. Pair not in exchange markets."
    save_ohlcv(zi[], exc.name, pair, timeframe, data; kwargs...)
end

export load_ohlcv, save_ohlcv
