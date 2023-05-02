using Exchanges
using OrderTypes

using ExchangeTypes: exc
import ExchangeTypes: exchangeid
using OrderTypes: OrderOrSide, AssetEvent
using Data: Data, load, zi, empty_ohlcv, DataFrame, DataStructures
using Data.DFUtils: daterange, timeframe
import Data: stub!
using TimeTicks
using Instruments: Instruments, compactnum, AbstractAsset, Cash
import Instruments: _hashtuple
using Misc: config, MarginMode, NoMargin, MM, DFT, Isolated, Cross
using .DataStructures: SortedDict
using Lang: Option

abstract type AbstractInstance{A<:AbstractAsset,E<:ExchangeID} end
include("positions.jl")

const Limits{T<:Real} = NamedTuple{(:leverage, :amount, :price, :cost),NTuple{4,MM{T}}}
const Precision{T<:Real} = NamedTuple{(:amount, :price),Tuple{T,T}}
const Fees{T<:Real} = NamedTuple{(:taker, :maker, :min, :max),NTuple{4,T}}

# TYPENUM
@doc "An asset instance holds all known state about an asset, i.e. `BTC/USDT`:
- `asset`: the identifier
- `data`: ohlcv series
- `history`: the trade history of the pair
- `cash`: how much is currently held, can be positive or negative (short)
- `exchange`: the exchange instance that this asset instance belongs to.
- `limits`: minimum order size (from exchange)
- `precision`: number of decimal points (from exchange)
"
struct AssetInstance15{T<:AbstractAsset,E<:ExchangeID,M<:MarginMode} <:
       AbstractInstance{T,E}
    asset::T
    data::SortedDict{TimeFrame,DataFrame}
    history::Vector{Trade{O,T,E} where O<:OrderType}
    logs::Vector{AssetEvent{E}}
    cash::Cash{S1,Float64} where {S1}
    cash_committed::Cash{S2,Float64} where {S2}
    exchange::Exchange{E}
    longpos::Option{Position{Long,<:WithMargin}}
    shortpos::Option{Position{Short,<:WithMargin}}
    limits::Limits{DFT}
    precision::Precision{DFT}
    fees::Fees{DFT}
    function AssetInstance15(
        a::A, data, e::Exchange{E}, ::M; limits, precision, fees
    ) where {A<:AbstractAsset,E<:ExchangeID,M<:MarginMode}
        local longpos, shortpos
        longpos, shortpos = positions(M, a, limits, e)
        new{A,E,M}(
            a,
            data,
            Trade{OrderType,A,E}[],
            AssetEvent{E}[],
            Cash{a.bc,Float64}(0.0),
            Cash{a.bc,Float64}(0.0),
            e,
            longpos::Option{Position{Long,<:WithMargin}},
            shortpos::Option{Position{Short,<:WithMargin}},
            limits,
            precision,
            fees,
        )
    end
end
AssetInstance = AssetInstance15

const NoMarginInstance{T,E} = AssetInstance{T,E,NoMargin}
const MarginInstance{D,E,M<:Union{Isolated,Cross}} = AssetInstance{D,E,M}

function positions(M::Type{<:MarginMode}, a::AbstractAsset, limits::Limits, e::Exchange)
    if M == NoMargin
        nothing, nothing
    else
        let pos_kwargs = (;
                asset=a, min_size=limits.amount.min, tiers=leverage_tiers(e, a.raw)
            )
            LongPosition{M}(; pos_kwargs...), ShortPosition{M}(; pos_kwargs...)
        end
    end
end
_hashtuple(ai::AssetInstance) = (Instruments._hashtuple(ai.asset)..., ai.exchange.id)
Base.hash(ai::AssetInstance) = hash(_hashtuple(ai))
Base.hash(ai::AssetInstance, h::UInt) = hash(_hashtuple(ai), h)
Base.propertynames(::AssetInstance) = (fieldnames(AssetInstance)..., :ohlcv)
Base.Broadcast.broadcastable(s::AssetInstance) = Ref(s)

@doc "Constructs an asset instance loading data from a zarr instance. Requires an additional external constructor defined in `Engine`."
function instance(exc::Exchange, a::AbstractAsset, m::MarginMode=NoMargin(); zi=zi)
    data = Dict()
    @assert a.raw ∈ keys(exc.markets) "Market $(a.raw) not found on exchange $(exc.name)."
    for tf in config.timeframes
        data[tf] = load(zi, exc.name, a.raw, string(tf))
    end
    AssetInstance(a; data, exc, margin=m)
end
instance(a) = instance(exc, a)

@doc "Load ohlcv data of asset instance."
function load!(a::AssetInstance; reset=true, zi=zi)
    for (tf, df) in a.data
        reset && empty!(df)
        loaded = load(zi, a.exchange.name, a.raw, string(tf))
        append!(df, loaded)
    end
end
Base.getproperty(a::AssetInstance, f::Symbol) = begin
    if f == :ohlcv
        first(getfield(a, :data)).second
    elseif f == :bc
        a.asset.bc
    elseif f == :qc
        a.asset.qc
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

function OrderTypes.Order(ai::AssetInstance, type; kwargs...)
    Order(ai.asset, ai.exchange.id, type; kwargs...)
end

@doc "Returns a similar asset instance with cash and orders reset."
function Base.similar(ai::AssetInstance)
    AssetInstance(
        ai.asset,
        ai.data,
        ai.exchange;
        limits=ai.limits,
        precision=ai.precision,
        fees=ai.fees,
    )
end

cash(ai::AssetInstance) = getfield(ai, :cash)
committed(ai::AssetInstance) = getfield(ai, :cash_committed)
ohlcv(ai::AssetInstance) = getfield(first(getfield(ai, :data)), :second)
Instruments.cash!(ai::AssetInstance, v) = cash!(cash(ai), v)
Instruments.add!(ai::AssetInstance, v) = add!(cash(ai), v)
Instruments.sub!(ai::AssetInstance, v) = sub!(cash(ai), v)
freecash(ai::AssetInstance) = cash(ai) - committed(ai)
Data.DFUtils.firstdate(ai::AssetInstance) = first(ohlcv(ai).timestamp)
Data.DFUtils.lastdate(ai::AssetInstance) = last(ohlcv(ai).timestamp)

function Base.string(ai::AssetInstance)
    "AssetInstance($(ai.bc)/$(ai.qc)[$(compactnum(ai.cash.value))]{$(ai.exchange.name)})"
end
Base.show(io::IO, ai::AssetInstance) = write(io, string(ai))
stub!(ai::AssetInstance, df::DataFrame) = begin
    tf = timeframe!(df)
    ai.data[tf] = df
end
@doc "Taker fees for the asset instance (usually higher than maker fees.)"
takerfees(ai::AssetInstance) = ai.fees.taker
@doc "Maker fees for the asset instance (usually lower than taker fees.)"
makerfees(ai::AssetInstance) = ai.fees.maker
@doc "The minimum fees for trading in the asset market (usually the highest vip level.)"
minfees(ai::AssetInstance) = ai.fees.min
@doc "The maximum fees for trading in the asset market (usually the lowest vip level.)"
maxfees(ai::AssetInstance) = ai.fees.max
@doc "ExchangeID for the asset instance."
exchangeid(::AssetInstance{<:AbstractAsset,E}) where {E<:ExchangeID} = E
@doc "Asset instance long position."
position(ai::MarginInstance, ::Type{Long}) = ai.longpos
@doc "Asset instance short position."
position(ai::MarginInstance, ::Type{Short}) = ai.shortpos
@doc "Position liquidation price."
function liquidation(ai::MarginInstance, ::OrderOrSide{S}) where {S<:PositionSide}
    position(ai, S()).liquidation_price[]
end
@doc "Position leverage."
function leverage(ai::MarginInstance, ::OrderOrSide{S}) where {S<:PositionSide}
    position(ai, S).leverage[]
end
@doc "Position status (open or closed)."
function status(ai::MarginInstance, ::OrderOrSide{S}) where {S<:PositionSide}
    position(ai, S).status[]
end
@doc "Position maintenance margin."
function maintenance(ai::MarginInstance, ::OrderOrSide{S}) where {S<:PositionSide}
    position(ai, S).maintenance_margin[]
end
@doc "Position initial margin."
function initial(ai::MarginInstance, ::OrderOrSide{S}) where {S<:PositionSide}
    position(ai, S).initial_margin[]
end
@doc "Position tier."
function tier(ai::MarginInstance, size, ::OrderOrSide{S}) where {S<:PositionSide}
    tier(position(ai, S), size)
end
@doc "Position maintenance margin rate."
function mmr(ai::MarginInstance, size, ::OrderOrSide{S}) where {S<:PositionSide}
    tier(ai, size, S).mmr
end

include("constructors.jl")

export AssetInstance, instance, load!
export takerfees, makerfees, maxfees, minfees
export Long, Short, position, liquidation, leverage
