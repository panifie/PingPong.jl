module Instances

using TimeTicks
using ExchangeTypes
using ExchangeTypes: exc
using Exchanges: market_fees, market_limits, market_precision, is_pair_active, getexchange!
using Data: Data, load, zi, empty_ohlcv, DataFrame, DataStructures
using Data.DFUtils: daterange, timeframe
using .DataStructures: SortedDict
using Instruments
import Instruments: _hashtuple
using Misc: config
using Processing
using ..Orders

const MM = NamedTuple{(:min, :max),Tuple{Float64,Float64}}
const Limits = NamedTuple{(:leverage, :amount, :price, :cost),NTuple{4,MM}}
const Precision = NamedTuple{(:amount, :price),Tuple{Real,Real}}

@doc "An asset instance holds all known state about an asset, i.e. `BTC/USDT`:
- `asset`: the identifier
- `data`: ohlcv series
- `history`: the trade history of the pair
- `cash`: how much is currently held, can be positive or negative (short)
- `exchange`: the exchange instance that this asset instance belongs to.
- `limits`: minimum order size (from exchange)
- `precision`: number of decimal points (from exchange)
"
struct AssetInstance41{T<:AbstractAsset,E<:ExchangeID}
    asset::T
    data::SortedDict{TimeFrame,DataFrame}
    history::Vector{Trade{<:OrderType,T,E}}
    cash::Cash{S,Float64} where {S}
    cash_committed::Cash{S,Float64} where {S}
    exchange::Ref{Exchange{E}}
    limits::Limits
    precision::Precision
    fees::Float64
    function AssetInstance41(
        a::A, data, e::Exchange{E}; min_amount=1e-8
    ) where {A<:AbstractAsset,E<:ExchangeID}
        limits = market_limits(a.raw, e; default_amount=(min=min_amount, max=Inf))
        precision = market_precision(a.raw, e)
        fees = market_fees(a.raw, e)
        new{A,E}(
            a,
            data,
            Trade{OrderType,A,E}[],
            Cash{a.bc,Float64}(0.0),
            Cash{a.bc,Float64}(0.0),
            e,
            limits,
            precision,
            fees,
        )
    end
    function AssetInstance41(a::A, args...; kwargs...) where {A<:AbstractAsset}
        AssetInstance41(a.asset, args...; kwargs...)
    end
    function AssetInstance41(s::S, t::S, e::S) where {S<:AbstractString}
        a = parse(AbstractAsset, s)
        tf = convert(TimeFrame, t)
        exc = getexchange!(Symbol(e))
        data = Dict(tf => load(zi, exc.name, a.raw, t))
        AssetInstance41(a, data, exc)
    end
end
AssetInstance = AssetInstance41

_hashtuple(ai::AssetInstance) = (Instruments._hashtuple(ai.asset)..., ai.exchange[].id)
Base.hash(ai::AssetInstance) = hash(_hashtuple(ai))
Base.hash(ai::AssetInstance, h::UInt) = hash(_hashtuple(ai), h)

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
    if f == :ohlcv
        first(getfield(a, :data)).second
    else
        getfield(a, f)
    end
end

@doc "Get the last available candle strictly lower than `apply(tf, date)`"
function Data.candlelast(ai::AssetInstance, tf::TimeFrame, date::DateTime)
    Data.candlelast(ai.data[tf], tf, date)
end

function Data.candlelast(ai::AssetInstance, date::DateTime)
    tf = first(keys(ai.data))
    Data.candlelast(ai, tf, date)
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

function _load_rest!(ai, tfs, from_tf, from_data)
    exc_name = ai.exchange[].name
    name = ai.asset.raw
    dr = daterange(from_data)
    for to_tf in tfs
        if to_tf ∉ Set(keys(ai.data)) # current tfs
            from_sto = load(
                zi, exc_name, ai.asset.raw, string(to_tf); from=dr.start, to=dr.stop
            )
            ai.data[to_tf] = if size(from_sto)[1] > 0 && daterange(from_sto) == dr
                from_sto
            else
                resample(from_data, from_tf, to_tf; exc_name, name)
            end
        end
    end
end

function Orders.Order(ai::AssetInstance, type; kwargs...)
    Order(ai.asset, ai.exchange[].id, type; kwargs...)
end

@doc "Pulls data from storage, or resample from the shortest timeframe available."
function Base.fill!(ai::AssetInstance, tfs...)
    # asset timeframes dict is sorted
    (from_tf, from_data) = first(ai.data)
    _check_timeframes(tfs, from_tf)
    _load_smallest!(ai, tfs, from_data, from_tf) || return nothing
    _load_rest!(ai, tfs, from_tf, from_data)
end

Instruments.cash!(ai::AssetInstance, v) = cash!(ai.cash, v)
Instruments.add!(ai::AssetInstance, v) = add!(ai.cash, v)
Instruments.sub!(ai::AssetInstance, v) = sub!(ai.cash, v)

export AssetInstance, isactive, instance, load!, lastcandle
end
