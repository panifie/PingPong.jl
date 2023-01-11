module Instances

using ExchangeTypes
using Exchanges: pair_fees, pair_min_size, pair_precision, is_pair_active, getexchange!
using Data: load_pair, zi
using TimeTicks
using DataFrames: DataFrame
using DataStructures: SortedDict
using Pairs
using ..Trades

@doc "An asset instance holds all known state about an asset, i.e. `BTC/USDT`:
- `asset`: the identifier
- `data`: ohlcv series
- `history`: the trade history of the pair
- `cash`: how much is currently held, can be positive or negative (short)
- `exchange`: the exchange instance that this asset instance belongs to.
- `minsize`: minimum order size (from exchange)
- `precision`: number of decimal points (from exchange)
"
struct AssetInstance12{T<:Asset}
    asset::T
    data::SortedDict{<:TimeFrame,DataFrame}
    history::Vector{Trade{T}}
    cash::Vector{Float64}
    exchange::Ref{Exchange}
    minsize::NamedTuple{(:b, :q),NTuple{2,Float64}}
    precision::NamedTuple{(:b, :q),NTuple{2,UInt8}}
    fees::Float64
    AssetInstance12(a::T, data, e::Exchange) where {T<:Asset} = begin
        minsize = pair_min_size(a.raw, e)
        precision = pair_precision(a.raw, e)
        fees = pair_fees(a.raw, e)
        new{typeof(a)}(a, data, Trade{T}[], Float64[0], e, minsize, precision, fees)
    end
    AssetInstance12(s::S, t::S, e::S) where {S<:AbstractString} = begin
        a = Asset(s)
        tf = convert(TimeFrame, t)
        exc = getexchange!(Symbol(e))
        data = Dict(tf => load_pair(zi, exc.name, a.raw, t))
        AssetInstance12(a, data, exc)
    end
    AssetInstance12(s, t) = AssetInstance12(s, t, exc)
end
AssetInstance = AssetInstance12

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
export AssetInstance, isactive, load!
end
