module Instances

using TimeTicks
using ExchangeTypes
using ExchangeTypes: exc
using Exchanges: market_fees, market_limits, market_precision, is_pair_active, getexchange!
using Data: load, zi, empty_ohlcv
using Data.DFUtils: daterange, timeframe
using Data: DataFrame
using DataStructures: SortedDict
using Instruments
using Misc: config
using Processing
using Reexport
using ..Orders

const MM = NamedTuple{(:min, :max),Tuple{Float64,Float64}}
const Limits = NamedTuple{(:leverage, :amount, :price, :cost),NTuple{4,MM}}

@doc "An asset instance holds all known state about an asset, i.e. `BTC/USDT`:
- `asset`: the identifier
- `data`: ohlcv series
- `history`: the trade history of the pair
- `cash`: how much is currently held, can be positive or negative (short)
- `exchange`: the exchange instance that this asset instance belongs to.
- `limits`: minimum order size (from exchange)
- `precision`: number of decimal points (from exchange)
"
struct AssetInstance27{T<:AbstractAsset,E<:ExchangeID}
    asset::T
    data::SortedDict{TimeFrame,DataFrame}
    history::Vector{Trade{Order{T,E}}}
    cash::Vector{Float64}
    exchange::Ref{Exchange{E}}
    limits::Limits
    precision::NamedTuple{(:amount, :price),Tuple{Real,Real}}
    fees::Float64
    function AssetInstance27(
        a::T, data, e::Exchange{I}
    ) where {T<:AbstractAsset,I<:ExchangeID}
        limits = market_limits(a.raw, e)
        precision = market_precision(a.raw, e)
        fees = market_fees(a.raw, e)
        new{T,I}(a, data, Trade{Order{T,I}}[], Float64[0], e, limits, precision, fees)
    end
    function AssetInstance27(a::A, args...; kwargs...) where {A<:AbstractAsset}
        AssetInstance27(a.asset, args...; kwargs...)
    end
    function AssetInstance27(s::S, t::S, e::S) where {S<:AbstractString}
        a = Asset(s)
        tf = convert(TimeFrame, t)
        exc = getexchange!(Symbol(e))
        data = Dict(tf => load(zi, exc.name, a.raw, t))
        AssetInstance27(a, data, exc)
    end
    AssetInstance27(s, t) = AssetInstance27(s, t, exc)
end
AssetInstance = AssetInstance27

function instance(exc::Exchange, a::AbstractAsset)
    data = Dict()
    @assert a.raw ∈ keys(exc.markets) "Market $(a.raw) not found on exchange $(exc.name)."
    for tf in config.timeframes
        data[tf] = load(zi, exc.name, a.raw, string(tf))
    end
    AssetInstance(a, data, exc)
end
instance(a) = instance(exc, a)

@doc "Load ohlcv data of asset instance."
function load!(a::AssetInstance; reset=true)
    for (tf, df) in a.data
        reset && empty!(df)
        loaded = load(zi, a.exchange.name, a.raw, string(tf))
        append!(df, loaded)
    end
end
isactive(a::AssetInstance) = is_pair_active(a.asset.raw, a.exchange)
Base.getproperty(a::AssetInstance, f::Symbol) = begin
    if f == :cash
        getfield(a, :cash)[1]
    else
        getfield(a, f)
    end
end
Base.setproperty!(a::AssetInstance, f::Symbol, v) = begin
    if f == :cash
        getfield(a, :cash)[1] = v
    else
        setfield!(a, f, v)
    end
end

@doc "Get the last available candle strictly lower than `apply(tf, date)`"
function last_candle(i::AssetInstance, tf::TimeFrame, date::DateTime)
    i.data[tf][available(tf, date)]
end

@inline function last_candle(i::AssetInstance, date::DateTime)
    tf = first(keys(i.data))
    last_candle(i, tf, date)
end

function _check_timeframes(tfs, from_tf)
    s_tfs = sort([t for t in tfs])
    sort!(s_tfs)
    if tfs[begin] < from_tf
        throw(
            ArgumentError("Timeframe $(tfs[begin]) is shorter than the shortest available.")
        )
    end
end

# Check if we have available data
function _load_smallest!(i, tfs, from_data, from_tf)
    if size(from_data)[1] == 0
        append!(from_data, load(zi, exc.name, i.asset.raw, string(from_tf)))
        if size(from_data)[1] == 0
            for to_tf in tfs
                i.data[to_tf] = empty_ohlcv()
            end
            return false
        end
        true
    else
        true
    end
end

function _load_rest!(i, tfs, from_tf, from_data)
    exc = i.exchange[]
    pairname = i.asset.raw
    dr = daterange(from_data)
    for to_tf in tfs
        if to_tf ∉ Set(keys(i.data)) # current tfs
            from_sto = load(
                zi, exc.name, i.asset.raw, string(to_tf); from=dr.start, to=dr.stop
            )
            i.data[to_tf] = if size(from_sto)[1] > 0 && daterange(from_sto) == dr
                from_sto
            else
                resample(exc, pairname, from_data, from_tf, to_tf; save=true)
            end
        end
    end
end

@doc "Pulls data from storage, or resample from the shortest timeframe available."
function Base.fill!(i::AssetInstance, tfs...)
    # asset timeframes dict is sorted
    (from_tf, from_data) = first(i.data)
    _check_timeframes(tfs, from_tf)
    _load_smallest!(i, tfs, from_data, from_tf) || return nothing
    _load_rest!(i, tfs, from_tf, from_data)
end

export AssetInstance, isactive, instance, load!, last_candle
end
