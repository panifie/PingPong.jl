using Exchanges
using OrderTypes

using ExchangeTypes: exc
import ExchangeTypes: exchangeid, exchange
using Exchanges: CurrencyCash
using OrderTypes: ByPos, AssetEvent, positionside
using Data: Data, load, zi, empty_ohlcv, DataFrame, DataStructures
using Data.DFUtils: daterange, timeframe
import Data: stub!
using Data.DataFrames: metadata
using TimeTicks
using Instruments: Instruments, compactnum, AbstractAsset, Cash, add!, sub!
import Instruments: _hashtuple, cash!, cash, freecash, value, raw, bc, qc
using Misc: config, MarginMode, NoMargin, WithMargin, MM, DFT, toprecision, ZERO
using Misc: Isolated, Cross, Hedged, IsolatedHedged, CrossHedged, CrossMargin
import Misc: approxzero, gtxzero, ltxzero, marginmode
using .DataStructures: SortedDict
using Lang: Option, @deassert
import Base: position, isopen
import Exchanges: lastprice, leverage!

abstract type AbstractInstance{A<:AbstractAsset,E<:ExchangeID} end

const Limits{T<:Real} = NamedTuple{(:leverage, :amount, :price, :cost),NTuple{4,MM{T}}}
const Precision{T<:Real} = NamedTuple{(:amount, :price),Tuple{T,T}}
const Fees{T<:Real} = NamedTuple{(:taker, :maker, :min, :max),NTuple{4,T}}
const CCash{E} = CurrencyCash{Cash{S,DFT},E} where {S}

include("positions.jl")

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
    cash::Option{CCash{E}{S1}} where {S1}
    cash_committed::Option{CCash{E}{S2}} where {S2}
    exchange::Exchange{E}
    longpos::Option{Position{Long,E,M}}
    shortpos::Option{Position{Short,E,M}}
    lastpos::Vector{Option{Position{P,E,M} where {P<:PositionSide}}}
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
            (CurrencyCash(e, a.bc, 0.0), CurrencyCash(e, a.bc, 0.0))
        else
            (nothing, nothing)
        end
        lastpos = Vector{Option{Position{<:PositionSide,E,M}}}()
        push!(lastpos, nothing)
        if !(ispercentage(e.markets[raw(a)]))
            @warn "Exchange uses fixed amount fees, fees calculation will not match!"
        end
        new{A,E,M}(
            a,
            data,
            Trade{OrderType,A,E}[],
            AssetEvent{E}[],
            cash,
            comm,
            e,
            longpos, #::Option{Position{Long,E,<:WithMargin}},
            shortpos, #::Option{Position{Short,E,<:WithMargin}},
            lastpos,
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
marginmode(::AssetInstance{<:AbstractAsset,<:ExchangeID,M}) where {M<:WithMargin} = M()
marginmode(::NoMarginInstance) = NoMargin()

function positions(M::Type{<:MarginMode}, a::AbstractAsset, limits::Limits, e::Exchange)
    if M == NoMargin
        nothing, nothing
    else
        let tiers = leverage_tiers(e, a.raw)
            function pos_kwargs()
                (;
                    asset=a,
                    min_size=limits.amount.min,
                    tiers=[tiers],
                    this_tier=[tiers[1]],
                    cash=CurrencyCash(e, a.bc, 0.0),
                    cash_committed=CurrencyCash(e, a.bc, 0.0),
                )
            end

            LongPosition{typeof(e.id),M}(; pos_kwargs()...),
            ShortPosition{typeof(e.id),M}(; pos_kwargs()...)
        end
    end
end

function _hashtuple(ai::AssetInstance)
    (
        Instruments._hashtuple(getfield(ai, :asset))...,
        getfield(getfield(ai, :exchange), :id),
    )
end
Base.hash(ai::AssetInstance) = hash(_hashtuple(ai))
Base.hash(ai::AssetInstance, h::UInt) = hash(_hashtuple(ai), h)
Base.propertynames(::AssetInstance) = (fieldnames(AssetInstance)..., :ohlcv, :funding)
Base.Broadcast.broadcastable(s::AssetInstance) = Ref(s)

posside(::NoMarginInstance) = Long()
posside(ai::MarginInstance) = posside(position(ai))
ishedged(::Union{T,Type{T}}) where {T<:MarginMode{H}} where {H} = H == Hedged
ishedged(ai::AssetInstance) = marginmode(ai) |> ishedged
isopen(ai::NoMarginInstance) = !iszero(ai)
isopen(ai::MarginInstance) =
    let po = position(ai)
        !isnothing(po) && isopen(po)
    end
islong(ai::NoMarginInstance) = true
isshort(ai::NoMarginInstance) = false
islong(ai::MarginInstance) =
    let pos = position(ai)
        isnothing(pos) && return false
        islong(pos)
    end
isshort(ai::MarginInstance) =
    let pos = position(ai)
        isnothing(pos) && return false
        isshort(pos)
    end

@doc "True if the position value of the asset is below minimum quantity."
function isdust(ai::MarginInstance, price, p::PositionSide)
    abs(cash(ai, p).value * price) < ai.limits.cost.min
end
@doc "True if the asset value is below minimum quantity."
function isdust(ai::AssetInstance, price)
    isdust(ai, price, Long()) && isdust(ai, price, Short())
end
@doc "Returns the asset cash rounded to precision."
function nondust(ai::MarginInstance, price, p=posside(ai))
    c = cash(ai, p)
    amt = c.value
    abs(amt * price) < ai.limits.cost.min ? zero(amt) : amt
end
@doc "Test if some amount (base currency) is zero w.r.t. an asset instance min limit."
function Base.iszero(ai::AssetInstance, v; atol=ai.limits.amount.min - eps(DFT))
    isapprox(v, zero(DFT); atol)
end
@doc "Test if asset cash is zero."
function Base.iszero(ai::AssetInstance, p::PositionSide)
    isapprox(value(cash(ai, p)), zero(DFT); atol=ai.limits.amount.min - eps(DFT))
end
@doc "Test if asset cash is zero."
function Base.iszero(ai::AssetInstance)
    iszero(ai, Long()) && iszero(ai, Short())
end
approxzero(ai::AssetInstance, args...; kwargs...) = iszero(ai, args...; kwargs...)
gtxzero(ai::AssetInstance, v, ::Val{:amount}) = gtxzero(v; atol=ai.limits.amount.min)
ltxzero(ai::AssetInstance, v, ::Val{:amount}) = ltxzero(v; atol=ai.limits.amount.min)
gtxzero(ai::AssetInstance, v, ::Val{:price}) = gtxzero(v; atol=ai.limits.price.min)
ltxzero(ai::AssetInstance, v, ::Val{:price}) = ltxzero(v; atol=ai.limits.price.min)
gtxzero(ai::AssetInstance, v, ::Val{:cost}) = gtxzero(v; atol=ai.limits.cost.min)
ltxzero(ai::AssetInstance, v, ::Val{:cost}) = ltxzero(v; atol=ai.limits.cost.min)
function Base.isapprox(ai::AssetInstance, v1, v2, ::Val{:amount})
    isapprox(v1, v2; atol=ai.precision.amount + eps(DFT))
end
function Base.isapprox(ai::AssetInstance, v1, v2, ::Val{:price})
    isapprox(v1, v2; atol=ai.precision.price + eps(DFT))
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
Base.getproperty(ai::AssetInstance, f::Symbol) = begin
    if f == :ohlcv
        ohlcv(ai)
    elseif f == :bc
        ai.asset.bc
    elseif f == :qc
        ai.asset.qc
    elseif f == :funding
        metadata(ohlcv(ai), "funding")
    else
        getfield(ai, f)
    end
end

@doc "The asset string id."
function asset(ai::AssetInstance)
    getfield(ai, :asset)
end

@doc "The asset string id."
function raw(ai::AssetInstance)
    raw(asset(ai))
end

bc(ai::AssetInstance) = bc(asset(ai))
qc(ai::AssetInstance) = qc(asset(ai))

@doc "Rounds a value based on the `precision` field of the `ai` asset instance. [`amount`]."
macro _round(v, kind=:amount)
    @assert kind isa Symbol
    quote
        toprecision(
            $(esc(v)), getfield(getfield($(esc(esc(:ai))), :precision), $(QuoteNode(kind)))
        )
    end
end

@doc "Rounds a value based on the `precision` (price) field of the `ai` asset instance."
macro rprice(v)
    quote
        $(@__MODULE__).@_round $(esc(v)) price
    end
end

@doc "Rounds a value based on the `precision` (amount) field of the `ai` asset instance."
macro ramount(v)
    quote
        $(@__MODULE__).@_round $(esc(v)) amount
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
function Base.similar(
    ai::AssetInstance; limits=ai.limits, precision=ai.precision, fees=ai.fees
)
    AssetInstance(ai.asset, ai.data, ai.exchange, marginmode(ai); limits, precision, fees)
end

cash(ai::NoMarginInstance) = getfield(ai, :cash)
cash(ai::NoMarginInstance, ::Long) = cash(ai)
cash(ai::NoMarginInstance, ::Short) = 0.0
cash(ai::MarginInstance) =
    let pos = position(ai)
        isnothing(pos) && return nothing
        getfield((pos), :cash)
    end
cash(ai::MarginInstance, ::Long) = getfield(position(ai, Long()), :cash)
cash(ai::MarginInstance, ::Short) = getfield(position(ai, Short()), :cash)
committed(ai::NoMarginInstance) = getfield(ai, :cash_committed)
committed(ai::NoMarginInstance, ::Long) = committed(ai)
committed(ai::NoMarginInstance, ::Short) = 0.0
function committed(ai::MarginInstance, ::ByPos{P}) where {P}
    getfield(position(ai, P), :cash_committed)
end
committed(ai::MarginInstance) = getfield((@something position(ai) ai), :cash_committed)
ohlcv(ai::AssetInstance) = getfield(first(getfield(ai, :data)), :second)
Instruments.add!(ai::NoMarginInstance, v, args...) = add!(cash(ai), v)
Instruments.add!(ai::MarginInstance, v, p::PositionSide) = add!(cash(ai, p), v)
Instruments.sub!(ai::NoMarginInstance, v, args...) = sub!(cash(ai), v)
Instruments.sub!(ai::MarginInstance, v, p::PositionSide) = sub!(cash(ai, p), v)
Instruments.cash!(ai::NoMarginInstance, v, args...) = cash!(cash(ai), v)
Instruments.cash!(ai::MarginInstance, v, p::PositionSide) = cash!(cash(ai, p), v)
Instruments.cash!(ai::NoMarginInstance, t::BuyTrade) = add!(cash(ai), t.amount)
# Positive `fees_base` go `trade --> exchange`
# Negative `fees_base` go `exchange --> trade`
# When reducing a position: t.amount is fee adjusted, but we need to update the local cash value,
# so we also need to deduct the `fees_base` qty, but only when those fees are paid
# from the trade to the exchange.
_deducted_amount(amt, fb) = fb > ZERO ? (amt > ZERO ? amt + fb : amt - fb) : amt
_deducted_amount(t::Trade) = _deducted_amount(t.amount, t.fees_base)
function Instruments.cash!(ai::NoMarginInstance, t::SellTrade)
    amt = _deducted_amount(t)
    add!(cash(ai), amt)
    add!(committed(ai), amt)
end
function Instruments.cash!(ai::MarginInstance, t::IncreaseTrade)
    add!(cash(ai, positionside(t)()), t.amount)
end
function Instruments.cash!(ai::MarginInstance, t::ReduceTrade)
    amt = _deducted_amount(t)
    add!(cash(ai, positionside(t)()), amt)
    add!(committed(ai, positionside(t)()), amt)
end
function freecash(ai::NoMarginInstance, args...)
    ca = cash(ai) - committed(ai)
    @deassert ca |> gtxzero (cash(ai), committed(ai))
    ca
end
function freecash(ai::MarginInstance, p::Long)
    @deassert cash(ai, p) |> gtxzero
    @deassert committed(ai, p) |> gtxzero
    ca = max(0.0, cash(ai, p) - committed(ai, p))
    @deassert ca |> gtxzero (cash(ai, p), committed(ai, p))
    ca
end
function freecash(ai::MarginInstance, p::Short)
    @deassert cash(ai, p) |> ltxzero
    @deassert committed(ai, p) |> ltxzero
    ca = min(0.0, cash(ai, p) - committed(ai, p))
    @deassert ca |> ltxzero (cash(ai, p), committed(ai, p))
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
reset!(ai::MarginInstance, args...) = begin
    reset!(position(ai, Short()), args...)
    reset!(position(ai, Long()), args...)
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
@doc "The exchange of the asset instance."
exchange(ai::AssetInstance) = getfield(ai, :exchange)
@doc "Asset instance long position."
position(ai::MarginInstance, ::ByPos{Long}) = getfield(ai, :longpos)
@doc "Asset instance short position."
position(ai::MarginInstance, ::ByPos{Short}) = getfield(ai, :shortpos)
@doc "Asset position by order."
position(ai::MarginInstance, ::ByPos{S}) where {S<:PositionSide} = position(ai, S)
@doc "Returns the last open asset position or nothing."
position(ai::MarginInstance) = getfield(ai, :lastpos)[]
@doc "Check if an asset position is open."
function isopen(ai::MarginInstance, ::ByPos{S}) where {S<:PositionSide}
    isopen(position(ai, S))
end
@doc "Asset position notional value."
function notional(ai::MarginInstance, ::ByPos{S}) where {S<:PositionSide}
    position(ai, S) |> notional
end
@doc "Asset entry price."
function price(ai::MarginInstance, fromprice, ::ByPos{S}) where {S<:PositionSide}
    v = position(ai, S) |> price
    ifelse(iszero(v), fromprice, v)
end
@doc "Asset entry price."
price(::NoMarginInstance, fromprice, args...) = fromprice
@doc "Asset position liquidation price."
function liqprice(ai::MarginInstance, ::ByPos{S}) where {S<:PositionSide}
    position(ai, S) |> liqprice
end
@doc "Sets asset position liquidation price."
function liqprice!(ai::MarginInstance, v, ::ByPos{S}) where {S<:PositionSide}
    liqprice!(position(ai, S), v)
end
@doc "Asset position leverage."
function leverage(ai::MarginInstance, ::ByPos{S}) where {S<:PositionSide}
    position(ai, S) |> leverage
end
leverage(::NoMarginInstance, args...) = 1.0
@doc "Asset position status (open or closed)."
function status(ai::MarginInstance, ::ByPos{S}) where {S<:PositionSide}
    position(ai, S) |> status
end
@doc "Asset position maintenance margin."
function maintenance(ai::MarginInstance, ::ByPos{S}) where {S<:PositionSide}
    position(ai, S) |> maintenance
end
@doc "Asset position initial margin."
function margin(ai::MarginInstance, ::ByPos{S}) where {S<:PositionSide}
    position(ai, S) |> margin
end
@doc "Asset position additional margin."
function additional(ai::MarginInstance, ::ByPos{S}) where {S<:PositionSide}
    position(ai, S) |> additional
end
@doc "Asset position tier."
function tier(ai::MarginInstance, size, ::ByPos{S}) where {S<:PositionSide}
    tier(position(ai, S), size)
end
@doc "Asset position maintenance margin rate."
function mmr(ai::MarginInstance, size, s::ByPos)
    mmr(position(ai, s), size)
end
@doc "The price where the asset position is fully liquidated."
function bankruptcy(ai, price, ps::Type{P}) where {P<:PositionSide}
    bankruptcy(position(ai, ps), price)
end
function bankruptcy(ai, o::Order{T,A,E,P}) where {T,A,E,P<:PositionSide}
    bankruptcy(ai, o.price, P())
end

@doc "Updates asset position leverage for asset instance."
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

value(v::Real, args...; kwargs...) = v
@doc "The value held by the position, margin with pnl minus fees."
function value(ai, ::ByPos{P}; current_price=price(position(ai, P)), fees=nothing) where {P}
    pos = position(ai, P)
    @deassert margin(pos) > 0.0 || !isopen(pos)
    @deassert additional(pos) >= 0.0
    fees = @something fees current_price * abs(cash(pos)) * maxfees(ai)
    margin(pos) + additional(pos) + pnl(pos, current_price) - fees
end

@doc "The pnl of an asset position."
function pnl(ai, ::ByPos{P}, price; pos=position(ai, P)) where {P}
    isnothing(pos) && return 0.0
    pnl(pos, price)
end

@doc "The pnl percentage of an asset position."
function pnlpct(ai::MarginInstance, ::ByPos{P}, price; pos=position(ai, P)) where {P}
    isnothing(pos) && return 0.0
    pnlpct(pos, price)
end
pnlpct(ai::MarginInstance, v::Number) = begin
    pos = position(ai)
    isnothing(pos) && return 0.0
    pnlpct(pos, v)
end

function lastprice(ai::AssetInstance, args...; kwargs...)
    lastprice(ai.asset.raw, ai.exchange, args...; kwargs...)
end

include("constructors.jl")

export AssetInstance, instance, load!, @rprice, @ramount
export asset, raw, ohlcv, bc, qc
export takerfees, makerfees, maxfees, minfees, ishedged, isdust, nondust
export Long, Short, position, posside, liqprice, leverage, bankruptcy, cash, committed, price
export leverage, mmr, status!
