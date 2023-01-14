module Instances

using TimeFrames: AbstractTimePeriodFrame
using TimeTicks: TimeFrames
using ExchangeTypes
using Exchanges: pair_fees, pair_min_size, pair_precision, is_pair_active, getexchange!
using Data: load_pair, zi
using Data.DFUtils: daterange, timeframe
using TimeTicks
using DataFrames: DataFrame
using DataStructures: SortedDict
using Pairs
using ..Trades
using Processing

@doc "An asset instance holds all known state about an asset, i.e. `BTC/USDT`:
- `asset`: the identifier
- `data`: ohlcv series
- `history`: the trade history of the pair
- `cash`: how much is currently held, can be positive or negative (short)
- `exchange`: the exchange instance that this asset instance belongs to.
- `minsize`: minimum order size (from exchange)
- `precision`: number of decimal points (from exchange)
"
struct AssetInstance20{T<:Asset, E<:ExchangeID}
    asset::T
    data::SortedDict{<:TimeFrame,DataFrame}
    history::Vector{Trade{T}}
    cash::Vector{Float64}
    exchange::Ref{Exchange{E}}
    minsize::NamedTuple{(:b, :q),NTuple{2,Float64}}
    precision::NamedTuple{(:b, :q),NTuple{2,UInt8}}
    fees::Float64
    AssetInstance20(a::T, data, e::Exchange) where {T<:Asset} = begin
        minsize = pair_min_size(a.raw, e)
        precision = pair_precision(a.raw, e)
        fees = pair_fees(a.raw, e)
        new{typeof(a), typeof(e.id)}(a, data, Trade{T}[], Float64[0], e, minsize, precision, fees)
    end
    AssetInstance20(s::S, t::S, e::S) where {S<:AbstractString} = begin
        a = Asset(s)
        tf = convert(TimeFrame, t)
        exc = getexchange!(Symbol(e))
        data = Dict(tf => load_pair(zi, exc.name, a.raw, t))
        AssetInstance20(a, data, exc)
    end
    AssetInstance20(s, t) = AssetInstance20(s, t, exc)
end
AssetInstance = AssetInstance20

@doc "Load ohlcv data of asset instance."
load!(a::AssetInstance; reset=true) = begin
    for (tf, df) in a.data
        reset && empty!(df)
        loaded = load_pair(zi, a.exchange.name, a.raw, tf)
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
    tf = keys(i.data) |> first
    last_candle(i, tf, date)
end

@doc "Pulls data from storage, or resample from the shortest timeframe available."
function Base.fill!(i::AssetInstance, tfs...)
    current_tfs = Set(keys(i.data))
    (from_tf, from_data) = first(i.data)
    s_tfs = sort([t for t in tfs])
    sort!(s_tfs)
    if tfs[begin] < from_tf
        throw(
            ArgumentError(
                "Timeframe $(tfs[begin]) is shorter than the shortest available.",
            ),
        )
    end
    exc = i.exchange[]
    pairname = i.asset.raw
    dr = daterange(from_data)
    for to_tf in tfs
        if to_tf ∉ current_tfs
            from_sto = load_pair(zi, exc.name, i.asset.raw, name(to_tf); from=dr.start, to=dr.stop)
            i.data[to_tf] = if size(from_sto)[1] > 0 && daterange(from_sto) == dr
                from_sto
            else
                resample(exc, pairname, from_data, from_tf, to_tf; save=true)
            end
        end
    end
end

export AssetInstance, isactive, load!, last_candle
end
