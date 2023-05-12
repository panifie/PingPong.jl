using Exchanges
using OrderTypes

using ExchangeTypes: exc
import ExchangeTypes: exchangeid
using OrderTypes: OrderOrSide, AssetEvent, tradepos
using Data: Data, load, zi, empty_ohlcv, DataFrame, DataStructures
using Data.DFUtils: daterange, timeframe
import Data: stub!
using Data.DataFrames: metadata
using TimeTicks
using Instruments: Instruments, compactnum, AbstractAsset, Cash, add!, sub!
import Instruments: _hashtuple, cash!, cash, freecash
using Misc: config, MarginMode, NoMargin, MM, DFT, add, sub, toprecision
using Misc: Isolated, Cross, Hedged, IsolatedHedged, CrossHedged, CrossMargin
using .DataStructures: SortedDict
using Lang: Option, @deassert
import Base: position, isopen

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
    cash::Option{Cash{S1,Float64}} where {S1}
    cash_committed::Option{Cash{S2,Float64}} where {S2}
    exchange::Exchange{E}
    longpos::Option{Position{Long,<:WithMargin}}
    shortpos::Option{Position{Short,<:WithMargin}}
    lastpos::Vector{Option{Position{<:PositionSide,<:WithMargin}}}
    limits::Limits{DFT}
    precision::Precision{DFT}
    fees::Fees{DFT}
    function AssetInstance15(
        a::A, data, e::Exchange{E}, margin::M; limits, precision, fees
    ) where {A<:AbstractAsset,E<:ExchangeID,M<:MarginMode}
        @assert !ishedged(margin) "Hedged margin not yet supported."
        local longpos, shortpos
        longpos, shortpos = positions(M, a, limits, e)
        cash, comm = if M == NoMargin
            (Cash{a.bc,DFT}(0.0), Cash{a.bc,DFT}(0.0))
        else
            (nothing, nothing)
        end
        new{A,E,M}(
            a,
            data,
            Trade{OrderType,A,E}[],
            AssetEvent{E}[],
            cash,
            comm,
            e,
            longpos::Option{Position{Long,<:WithMargin}},
            shortpos::Option{Position{Short,<:WithMargin}},
            [nothing],
            limits,
            precision,
            fees,
        )
    end
end
AssetInstance = AssetInstance15

const NoMarginInstance = AssetInstance{<:AbstractAsset,<:ExchangeID,NoMargin}
const MarginInstance{M<:Union{Isolated,Cross}} = AssetInstance{
    <:AbstractAsset,<:ExchangeID,M
}
const HedgedInstance{M<:Union{IsolatedHedged,CrossHedged}} = AssetInstance{
    <:AbstractAsset,<:ExchangeID,M
}
const CrossInstance{M<:CrossMargin} = AssetInstance{<:AbstractAsset,<:ExchangeID,M}

function positions(M::Type{<:MarginMode}, a::AbstractAsset, limits::Limits, e::Exchange)
    if M == NoMargin
        nothing, nothing
    else
        let tiers = leverage_tiers(e, a.raw),
            pos_kwargs = (;
                asset=a,
                min_size=limits.amount.min,
                tiers=[tiers],
                this_tier=[tiers[1]],
                cash=Cash(a.bc, 0.0),
                cash_committed=Cash(a.bc, 0.0),
            )

            LongPosition{M}(; pos_kwargs...), ShortPosition{M}(; pos_kwargs...)
        end
    end
end
_hashtuple(ai::AssetInstance) = (Instruments._hashtuple(ai.asset)..., ai.exchange.id)
Base.hash(ai::AssetInstance) = hash(_hashtuple(ai))
Base.hash(ai::AssetInstance, h::UInt) = hash(_hashtuple(ai), h)
Base.propertynames(::AssetInstance) = (fieldnames(AssetInstance)..., :ohlcv, :funding)
Base.Broadcast.broadcastable(s::AssetInstance) = Ref(s)

posside(::NoMarginInstance) = Long()
posside(ai::MarginInstance) = posside(position(ai))()
ishedged(::Union{T,Type{T}}) where {T<:MarginMode{H}} where {H} = H == Hedged
isopen(ai::NoMarginInstance) = !iszero(ai)
isopen(ai::MarginInstance) =
    let po = position(ai)
        !isnothing(po) && isopen(po)
    end

@doc "True if the position value of the asset is below minimum quantity."
function isdust(ai::MarginInstance, price, p::PositionSide)
    abs(toprecision(cash(ai, p).value, ai.precision.amount) * price) < ai.limits.cost.min
end
@doc "True if the asset value is below minimum quantity."
function isdust(ai::AssetInstance, price)
    isdust(ai, price, Long()) && isdust(ai, price, Short())
end
@doc "Returns the asset cash rounded to precision."
function nondust(ai::MarginInstance, price, p=posside(ai))
    c = cash(ai, p)
    amt = toprecision(c.value, ai.precision.amount)
    abs(amt * price) < ai.limits.cost.min ? zero(c) : amt
end
@doc "Test if some amount (base currency) is zero w.r.t. an asset instance min limit."
function Base.iszero(ai::AssetInstance, v)
    isapprox(v, 0.0; atol=ai.limits.amount.min - eps(DFT))
end
@doc "Test if asset cash is zero."
function Base.iszero(ai::AssetInstance)
    isapprox(cash(ai), 0.0; atol=ai.limits.amount.min - eps(DFT))
end

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
_ohlcv(ai) = first(getfield(ai, :data)).second
Base.getproperty(ai::AssetInstance, f::Symbol) = begin
    if f == :ohlcv
        _ohlcv(ai)
    elseif f == :bc
        ai.asset.bc
    elseif f == :qc
        ai.asset.qc
    elseif f == :funding
        metadata(_ohlcv(ai), "funding")
    else
        getfield(ai, f)
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

cash(ai::NoMarginInstance) = getfield(ai, :cash)
cash(ai::NoMarginInstance, ::Long) = cash(ai)
cash(ai::NoMarginInstance, ::Short) = 0.0
cash(ai::MarginInstance, p::PositionSide) = getfield(position(ai, p), :cash)
committed(ai::NoMarginInstance) = getfield(ai, :cash_committed)
committed(ai::NoMarginInstance, ::Long) = committed(ai)
committed(ai::NoMarginInstance, ::Short) = 0.0
function committed(ai::MarginInstance, p::PositionSide)
    getfield(position(ai, p), :cash_committed)
end
ohlcv(ai::AssetInstance) = getfield(first(getfield(ai, :data)), :second)
Instruments.add!(ai::NoMarginInstance, v, args...) = add!(cash(ai), v)
Instruments.add!(ai::MarginInstance, v, p::PositionSide) = add!(cash(ai, p), v)
Instruments.sub!(ai::NoMarginInstance, v, args...) = sub!(cash(ai), v)
Instruments.sub!(ai::MarginInstance, v, p::PositionSide) = sub!(cash(ai, p), v)
Instruments.cash!(ai::NoMarginInstance, v, args...) = cash!(cash(ai), v)
Instruments.cash!(ai::MarginInstance, v, p::PositionSide) = cash!(cash(ai, p), v)
Instruments.cash!(ai::NoMarginInstance, t::BuyTrade) = add!(cash(ai), t.amount)
function Instruments.cash!(ai::NoMarginInstance, t::SellTrade)
    add!(cash(ai), t.amount)
    add!(committed(ai), t.amount)
end
function Instruments.cash!(ai::MarginInstance, t::IncreaseTrade)
    add!(cash(ai, tradepos(t)()), t.amount)
end
function Instruments.cash!(ai::MarginInstance, t::ReduceTrade)
    add!(cash(ai, tradepos(t)()), t.amount)
    add!(committed(ai, tradepos(t)()), t.amount)
end
freecash(ai::NoMarginInstance, args...) = begin
    ca = cash(ai) - committed(ai)
    @deassert ca >= 0.0 (cash(ai), committed(ai))
    ca
end
_freecash(ai, p) = sub(cash(ai, p), committed(ai, p), p)
function freecash(ai::MarginInstance, p::Long)
    ca = _freecash(ai, p)
    @deassert ca >= 0.0 (cash(ai, p), committed(ai, p))
    ca
end
function freecash(ai::MarginInstance, p::Short)
    ca = _freecash(ai, p)
    @deassert ca <= 0.0 (cash(ai, p), committed(ai, p))
    ca
end
_reset!(ai) = begin
    empty!(ai.history)
    empty!(ai.logs)
    ai.lastpos[] = nothing
end
@doc "Resets asset cash and committments."
reset!(ai::NoMarginInstance, args...) = begin
    cash!(ai, 0.0)
    cash!(committed(ai), 0.0)
    _reset!(ai)
end
@doc "Resets asset positions."
reset!(ai::MarginInstance) = begin
    reset!(position(ai, Short()))
    reset!(position(ai, Long()))
    _reset!(ai)
end
reset!(ai::MarginInstance, p::PositionSide) = begin
    reset!(position(ai, p))
    let sop = position(ai, opposite(p))
        if isopen(sop)
            ai.lastpos[] = sop
        else
            ai.lastpos[] = nothing
        end
    end
end
Data.DFUtils.firstdate(ai::AssetInstance) = first(ohlcv(ai).timestamp)
Data.DFUtils.lastdate(ai::AssetInstance) = last(ohlcv(ai).timestamp)

function Base.string(ai::NoMarginInstance)
    "AssetInstance($(ai.bc)/$(ai.qc)[$(compactnum(ai.cash.value))]{$(ai.exchange.name)})"
end
function Base.string(ai::MarginInstance)
    long = compactnum(cash(ai, Long()).value)
    short = compactnum(cash(ai, Short()).value)
    "AssetInstance($(ai.bc)/$(ai.qc)[L:$long/S:$short]{$(ai.exchange.name)})"
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
position(ai::MarginInstance, ::Type{Long}) = getfield(ai, :longpos)
@doc "Asset instance short position."
position(ai::MarginInstance, ::Type{Short}) = getfield(ai, :shortpos)
@doc "Position by order."
position(ai::MarginInstance, ::OrderOrSide{S}) where {S<:PositionSide} = position(ai, S)
@doc "Returns the last open position or nothing."
position(ai::MarginInstance) = getfield(ai, :lastpos)[]
@doc "Check if an asset position is open."
function isopen(ai::MarginInstance, ::OrderOrSide{S}) where {S<:PositionSide}
    isopen(position(ai, S))
end
@doc "Position liquidation price."
function liqprice(ai::MarginInstance, ::OrderOrSide{S}) where {S<:PositionSide}
    position(ai, S) |> liqprice
end
@doc "Sets liquidation price."
function liqprice!(ai::MarginInstance, v, ::OrderOrSide{S}) where {S<:PositionSide}
    liqprice!(position(ai, S), v)
end
@doc "Position leverage."
function leverage(ai::MarginInstance, ::OrderOrSide{S}) where {S<:PositionSide}
    position(ai, S) |> leverage
end
@doc "Position status (open or closed)."
function status(ai::MarginInstance, ::OrderOrSide{S}) where {S<:PositionSide}
    position(ai, S) |> status
end
@doc "Position maintenance margin."
function maintenance(ai::MarginInstance, ::OrderOrSide{S}) where {S<:PositionSide}
    position(ai, S) |> maintenance
end
@doc "Position initial margin."
function initial(ai::MarginInstance, ::OrderOrSide{S}) where {S<:PositionSide}
    position(ai, S) |> initial
end
@doc "Position tier."
function tier(ai::MarginInstance, size, ::OrderOrSide{S}) where {S<:PositionSide}
    tier(position(ai, S), size)
end
@doc "Position maintenance margin rate."
function mmr(ai::MarginInstance, size, s::OrderOrSide)
    mmr(position(ai, s), size)
end
@doc "The price where the position is fully liquidated."
function bankruptcy(ai, price, ps::Type{P}) where {P<:PositionSide}
    bankruptcy(position(ai, ps), price)
end
function bankruptcy(ai, o::Order{T,A,E,P}) where {T,A,E,P<:PositionSide}
    bankruptcy(ai, o.price, P())
end

@doc "Updates position leverage for asset instance."
function leverage!(ai, v, p::PositionSide)
    po = position(ai, p)
    leverage!(po, v)
    # ensure leverage tiers and limits agree
    @deassert leverage(po) <= ai.limits.leverage.max
end

@doc "Some exchanges consider a value of 0 leverage as max leverage for the current tier (in cross margin mode)."
function leverage!(ai::CrossInstance, p::PositionSide, ::Val{:max})
    po = position(ai, p)
    po.leverage[] = 0.0
end

@doc "The opposite position w.r.t. the asset instance and another `Position` or `PositionSide`."
function opposite(ai::MarginInstance, ::Union{P,Position{P}}) where {P}
    position(ai, opposite(P))
end

function _lastpos!(ai::MarginInstance, p::PositionSide, ::PositionClose)
    sop = position(ai, opposite(p))
    isopen(sop) && (ai.lastpos[] = sop)
end

function _lastpos!(ai::MarginInstance, p::PositionSide, ::PositionOpen)
    ai.lastpos[] = position(ai, p)
end

@doc "Opens or closes the status of an hedged position."
function status!(ai::HedgedInstance, p::PositionSide, pstat::PositionStatus)
    pos = position(ai, p)
    _status!(pos, pstat)
    _lastpos!(ai, p, pstat)
end

@doc "Opens or closes the status of an non-hedged position."
function status!(ai::MarginInstance, p::PositionSide, pstat::PositionStatus)
    pos = position(ai, p)
    @assert pstat == PositionOpen() ? status(opposite(ai, p)) == PositionClose() : true "Can only have either long or short position open in non-hedged mode, not both."
    _status!(pos, pstat)
    _lastpos!(ai, p, pstat)
end

include("constructors.jl")

export AssetInstance, instance, load!
export takerfees, makerfees, maxfees, minfees, ishedged, isdust, nondust
export Long, Short, position, liqprice, leverage, bankruptcy, cash, committed
export leverage, mmr, status!
