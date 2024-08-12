using Exchanges
using OrderTypes

import Exchanges.ExchangeTypes: exchangeid, exchange, exc
using Exchanges: CurrencyCash, Data, TICKERS_CACHE10, markettype, @tickers!
using OrderTypes: ByPos, AssetEvent, positionside, Instruments, ordertype
using .Data: load, zi, empty_ohlcv, DataFrame, DataStructures
using .Data.DFUtils: daterange, timeframe
import .Data: stub!
using .Data.DataFrames: metadata
using .Instruments: Instruments, compactnum, AbstractAsset, Cash, add!, sub!, Misc
import .Instruments: _hashtuple, cash!, cash, freecash, value, raw, bc, qc
using .Misc: config, MarginMode, NoMargin, WithMargin, MM, DFT, toprecision, ZERO
using .Misc: Lang, TimeTicks, SortedArray
using .Misc: Isolated, Cross, Hedged, IsolatedHedged, CrossHedged, CrossMargin
using .Misc.DocStringExtensions
import .Misc: approxzero, gtxzero, ltxzero, marginmode, load!
using .TimeTicks
import .TimeTicks: timeframe
using .DataStructures: SortedDict
using .Lang: Option, @deassert, @lget!, @caller
import Base: position, isopen
import Exchanges: lastprice, leverage!
import OrderTypes: trades

baremodule InstancesLock end

@doc """Defines the abstract type for an instance.

The `AbstractInstance` type is a generic abstract type for an instance. It is parameterized by two types: `A`, which must be a subtype of `AbstractAsset`, and `E`, which must be a subtype of `ExchangeID`.
"""
abstract type AbstractInstance{A<:AbstractAsset,E<:ExchangeID} end

@doc "Defines a NamedTuple structure for limits, including leverage, amount, price, and cost, each of which is a subtype of Real."
const Limits{T<:Real} = NamedTuple{(:leverage, :amount, :price, :cost),<:NTuple{4,MM{<:T}}}
@doc "Defines a NamedTuple structure for precision, including amount and price, each of which is a subtype of Real."
const Precision{T<:Real} = NamedTuple{(:amount, :price),<:Tuple{<:T,<:T}}
@doc "Defines a NamedTuple structure for fees, including taker, maker, minimum, and maximum fees, each of which is a subtype of Real."
const Fees{T<:Real} = NamedTuple{(:taker, :maker, :min, :max),<:NTuple{4,<:T}}
@doc "Defines a type for currency cash, which is parameterized by an exchange `E` and a symbol `S`."
const CCash{E} = CurrencyCash{Cash{S,DFT},E} where {S}
const AnyTrade{T,E} = Trade{O,T,E} where {O<:OrderType}

include("positions.jl")

@doc """Defines a structure for an asset instance.

$(FIELDS)

An `AssetInstance` holds all known state about an exchange asset like `BTC/USDT`.
"""
struct AssetInstance{T<:AbstractAsset,E<:ExchangeID,M<:MarginMode} <: AbstractInstance{T,E}
    "The identifier of the asset."
    asset::T
    "The OHLCV (Open, High, Low, Close, Volume) series for the asset."
    data::SortedDict{TimeFrame,DataFrame}
    "The trade history of the pair."
    history::SortedArray{AnyTrade{T,E},1}
    "A lock for synchronizing access to the asset instance."
    lock::ReentrantLock
    "The amount of the asset currently held. This can be positive or negative (short)."
    cash::Option{CCash{E}{S1}} where {S1}
    "The amount of the asset currently committed for orders."
    cash_committed::Option{CCash{E}{S2}} where {S2}
    "The exchange instance that this asset instance belongs to."
    exchange::Exchange{E}
    "The long position of the asset."
    longpos::Option{Position{Long,E,M}}
    "The short position of the asset."
    shortpos::Option{Position{Short,E,M}}
    "The last position of the asset."
    lastpos::Vector{Option{Position{P,E,M} where {P<:PositionSide}}}
    "The minimum order size (from the exchange)."
    limits::Limits{DFT}
    "The number of decimal points (from the exchange)."
    precision::Precision{<:Union{Int,DFT}}
    "The fees associated with the asset (from the exchange)."
    fees::Fees{DFT}
    @doc """ Create an `AssetInstance` object.

    $(TYPEDSIGNATURES)

    This function constructs an `AssetInstance` with defined asset, data, exchange, margin, and optional parameters for limits, precision, and fees. It initializes long and short positions based on the provided margin and ensures that the margin is not hedged.

    """
    function AssetInstance(
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
            SortedArray(AnyTrade{A,E}[]; by=trade -> trade.date),
            ReentrantLock(),
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

@doc "A type alias representing an asset instance with no margin."
const NoMarginInstance = AssetInstance{<:AbstractAsset,<:ExchangeID,NoMargin}
@doc "A type alias for an asset instance with either isolated or cross margin."
const MarginInstance{M<:Union{Isolated,Cross}} = AssetInstance{
    <:AbstractAsset,<:ExchangeID,M
}
@doc "A type alias for an asset instance with either isolated or cross hedged margin."
const HedgedInstance{M<:Union{IsolatedHedged,CrossHedged}} = AssetInstance{
    <:AbstractAsset,<:ExchangeID,M
}
@doc "A type alias representing an asset instance with cross margin."
const CrossInstance{M<:CrossMargin} = AssetInstance{<:AbstractAsset,<:ExchangeID,M}
@doc " Retrieve the margin mode of an `AssetInstance`. "
marginmode(::AssetInstance{<:AbstractAsset,<:ExchangeID,M}) where {M<:WithMargin} = M()
marginmode(::NoMarginInstance) = NoMargin()

@doc """ Generate positions for a specific margin mode.

$(TYPEDSIGNATURES)

This function generates long and short positions for a given asset on a specific exchange. The number and size of the positions are determined by the `limits` argument and the margin mode `M`.

"""
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
                    this_tier=[first(values(tiers))],
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
function Base.lock(ai::AssetInstance)
    @debug "locking $(raw(ai))" _module = InstancesLock tid = Threads.threadid() f = @caller 14
    lock(getfield(ai, :lock))
    @debug "locked $(raw(ai))" _module = InstancesLock tid = Threads.threadid() f = @caller 14
end
Base.lock(f, ai::AssetInstance) = lock(f, getfield(ai, :lock))
function Base.unlock(ai::AssetInstance)
    unlock(getfield(ai, :lock))
    @debug "unlocked $(raw(ai))" _module = InstancesLock tid = Threads.threadid() f = @caller 14
end
Base.islocked(ai::AssetInstance) = islocked(getfield(ai, :lock))
@doc " Get the cash value of a `AssetInstance`. "
Base.float(ai::AssetInstance) = nothing
Base.float(ai::NoMarginInstance) = cash(ai).value
Base.float(ai::MarginInstance) =
    let c = cash(ai)
        @something c.value 0.0
    end

posside(::NoMarginInstance) = Long()
@doc "Get the position side of an `AssetInstance`. "
posside(ai::MarginInstance) =
    let pos = position(ai)
        isnothing(pos) ? nothing : posside(pos)
    end
_ishedged(::Union{T,Type{T}}) where {T<:MarginMode{H}} where {H} = H == Hedged
# NOTE: wrap the function here to quickly overlay methods
@doc "Check if the margin mode is hedged."
ishedged(args...; kwargs...) = _ishedged(args...; kwargs...)
@doc "Check if the `AssetInstance` is hedged."
ishedged(ai::AssetInstance) = marginmode(ai) |> ishedged
@doc "Check if the `AssetInstance` is open."
isopen(ai::NoMarginInstance) = !iszero(ai)
isopen(ai::MarginInstance) =
    let po = position(ai)
        !isnothing(po) && isopen(po)
    end
@doc "Check if the `AssetInstance` is long."
islong(ai::NoMarginInstance) = true
@doc "Check if the `AssetInstance` is short."
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

@doc """ Check if the position value of the asset is below minimum quantity.

$(TYPEDSIGNATURES)

This function checks if the position value of a given `AssetInstance` at a specific price is below the minimum limit for that asset. The position side `p` determines if it's a long or short position.

"""
function isdust(ai::MarginInstance, price::Number, p::PositionSide)
    pos = position(ai, p)
    if isnothing(pos)
        return true
    end
    this_cash = cash(pos) |> value |> abs
    if this_cash >= ai.limits.amount.min
        return false
    else
        this_cash * price * leverage(pos) < ai.limits.cost.min
    end
end
function isdust(ai::MarginInstance, price::Number)
    isdust(ai, price, Long()) && isdust(ai, price, Short())
end
function isdust(ai::NoMarginInstance, price::Number)
    this_cash = cash(ai) |> value |> abs
    if this_cash >= ai.limits.amount.min
        return false
    else
        this_cash * price < ai.limits.cost.min
    end
end
function isdust(ai::AssetInstance, o::Type{<:Order}, price::Number)
    if o <: ReduceOnlyOrder
        false
    else
        invoke(isdust, Tuple{MarginInstance,Number,PositionSide}, ai, price, posside(ai))
    end
end
@doc """ Get the asset cash rounded to precision.

$(TYPEDSIGNATURES)

This function returns the asset cash of a `MarginInstance` rounded according to the asset's precision. The position side `p` is determined by the `posside` function.

"""
function nondust(ai::MarginInstance, price::Number, p=posside(ai))
    pos = position(ai, p)
    if isnothing(pos)
        return zero(price)
    end
    c = cash(pos)
    amt = c.value
    abs(amt * price * leverage(pos)) < ai.limits.cost.min ? zero(amt) : amt
end

function nondust(ai::MarginInstance, o::Type{<:Order}, price)
    if o <: ReduceOnlyOrder
        cash(ai, o).value
    else
        invoke(nondust, Tuple{MarginInstance,Number,PositionSide}, ai, price, posside(o))
    end
end

@doc """ Check if the amount is below the asset instance's minimum limit.

$(TYPEDSIGNATURES)

This function checks if a specified amount in base currency is considered zero with respect to an `AssetInstance`'s minimum limit. The amount is considered zero if it is less than the minimum limit minus a small epsilon value.

"""
function Base.iszero(ai::AssetInstance, v; atol=ai.limits.amount.min - eps(DFT))
    isapprox(v, zero(DFT); atol)
end
@doc """ Check if the asset cash for a position side is zero.

$(TYPEDSIGNATURES)

This function checks if the cash value of an `AssetInstance` for a specific `PositionSide` is zero. This is used to determine if there are no funds in a certain position side (long or short).

"""
function Base.iszero(ai::AssetInstance, p::PositionSide)
    isapprox(value(cash(ai, p)), zero(DFT); atol=ai.limits.amount.min - eps(DFT))
end
@doc """ Check if the asset cash is zero.

$(TYPEDSIGNATURES)

This function checks if the cash value of an `AssetInstance` is zero. This is used to determine if there are no funds in the asset.

"""
function Base.iszero(ai::AssetInstance)
    iszero(ai, Long()) && iszero(ai, Short())
end
approxzero(ai::AssetInstance, args...; kwargs...) = iszero(ai, args...; kwargs...)
@doc """ Check if an amount is greater than zero for an `AssetInstance`.

$(TYPEDSIGNATURES)

This function checks if a specified amount `v` is greater than zero for an `AssetInstance`. It's used to validate the amount before performing operations on the asset.

"""
function gtxzero(ai::AssetInstance, v, ::Val{:amount})
    gtxzero(v; atol=ai.limits.amount.min + eps())
end
@doc """ Check if an amount is less than zero for an `AssetInstance`.

$(TYPEDSIGNATURES)

This function checks if a specified amount `v` is less than zero for an `AssetInstance`. It's used to validate the amount before performing operations on the asset.

"""
function ltxzero(ai::AssetInstance, v, ::Val{:amount})
    ltxzero(v; atol=ai.limits.amount.min + eps())
end
@doc """ Check if a price is greater than zero for an `AssetInstance`.

$(TYPEDSIGNATURES)

This function checks if a specified price `v` is greater than zero for an `AssetInstance`. The price is considered greater than zero if it is above the minimum limit minus a small epsilon value.

"""
gtxzero(ai::AssetInstance, v, ::Val{:price}) = gtxzero(v; atol=ai.limits.price.min + eps())
@doc """ Check if a price is less than zero for an `AssetInstance`.

$(TYPEDSIGNATURES)

This function checks if a specified price `v` is less than zero for an `AssetInstance`. The price is considered less than zero if it is below the minimum limit minus a small epsilon value.

"""
ltxzero(ai::AssetInstance, v, ::Val{:price}) = ltxzero(v; atol=ai.limits.price.min + eps())
@doc """ Check if a cost is greater than zero for an `AssetInstance`.

$(TYPEDSIGNATURES)

This function checks if a specified cost `v` is greater than zero for an `AssetInstance`. The cost is considered greater than zero if it is above the minimum limit minus a small epsilon value.

"""
gtxzero(ai::AssetInstance, v, ::Val{:cost}) = gtxzero(v; atol=ai.limits.cost.min + eps())
@doc """ Check if a cost is less than zero for an `AssetInstance`.

$(TYPEDSIGNATURES)

This function checks if a specified cost `v` is less than zero for an `AssetInstance`. The cost is considered less than zero if it is below the minimum limit minus a small epsilon value.

"""
ltxzero(ai::AssetInstance, v, ::Val{:cost}) = ltxzero(v; atol=ai.limits.cost.min + eps())
@doc """ Check if two amounts are approximately equal for an `AssetInstance`.

$(TYPEDSIGNATURES)

This function checks if two specified amounts `v1` and `v2` are approximately equal for an `AssetInstance`. It's used to validate whether two amounts are similar considering small variations.

"""
function Base.isapprox(
    ai::AssetInstance, v1, v2, ::Val{:amount}; atol=ai.precision.amount + eps(DFT)
)
    isapprox(value(v1), value(v2); atol)
end
@doc """ Check if two prices are approximately equal for an `AssetInstance`.

$(TYPEDSIGNATURES)

This function checks if two specified prices `v1` and `v2` are approximately equal for an `AssetInstance`. It's used to validate whether two prices are similar considering small variations.

"""
function Base.isapprox(
    ai::AssetInstance, v1, v2, ::Val{:price}; atol=ai.precision.price + eps(DFT)
)
    isapprox(value(v1), value(v2); atol)
end

function Base.isequal(ai::AssetInstance, v1, v2, kind::Val{:amount})
    isapprox(ai, v1, v2, kind; atol=ai.limits.amount.min - eps(DFT))
end

function Base.isequal(ai::AssetInstance, v1, v2, kind::Val{:price})
    isapprox(ai, v1, v2, kind; atol=ai.limits.price.min - eps(DFT))
end

@doc """ Create an `AssetInstance` from a zarr instance.

$(TYPEDSIGNATURES)

This function constructs an `AssetInstance` by loading data from a zarr instance and requires an external constructor defined in `Engine`. The `MarginMode` can be specified, with `NoMargin` being the default.

"""
function instance(exc::Exchange, a::AbstractAsset, m::MarginMode=NoMargin(); zi=zi)
    data = Dict()
    @assert a.raw ∈ keys(exc.markets) "Market $(a.raw) not found on exchange $(exc.name)."
    for tf in config.timeframes
        data[tf] = load(zi, exc.name, a.raw, string(tf))
    end
    AssetInstance(a; data, exc, margin=m)
end
instance(a) = instance(exc, a)

@doc """ Load OHLCV data for an `AssetInstance`.

$(TYPEDSIGNATURES)

This function loads OHLCV (Open, High, Low, Close, Volume) data for a given `AssetInstance`. If `reset` is set to true, it will re-fetch the data even if it's already been loaded.

"""
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

@doc " Get the parsed `AbstractAsset` of an `AssetInstance`. "
function asset(ai::AssetInstance)
    getfield(ai, :asset)
end

@doc " Get the raw string id of an `AssetInstance`. "
function raw(ai::AssetInstance)
    raw(asset(ai))
end

@doc " Get the base currency of an `AssetInstance`. "
bc(ai::AssetInstance) = bc(asset(ai))
@doc " Get the quote currency of an `AssetInstance`. "
qc(ai::AssetInstance) = qc(asset(ai))

@doc """ Round a value based on the `precision` field of the `ai` asset instance.

$(TYPEDSIGNATURES)

This macro rounds a value `v` based on the `precision` field of an `AssetInstance`. By default, it rounds the `amount`, but it can also round other fields like `price` or `cost` if specified.

"""
macro _round(v, kind=:amount)
    @assert kind isa Symbol
    quote
        toprecision(
            $(esc(v)), getfield(getfield($(esc(esc(:ai))), :precision), $(QuoteNode(kind)))
        )
    end
end

@doc """ Round a value based on the `precision` (price) field of the `ai` asset instance.

$(TYPEDSIGNATURES)

This macro rounds a price value `v` based on the `precision` field of an `AssetInstance`.

"""
macro rprice(v)
    quote
        $(@__MODULE__).@_round $(esc(v)) price
    end
end

@doc """ Round a value based on the `precision` (amount) field of the `ai` asset instance.

$(TYPEDSIGNATURES)

This macro rounds an amount value `v` based on the `precision` field of an `AssetInstance`.

"""
macro ramount(v)
    quote
        $(@__MODULE__).@_round $(esc(v)) amount
    end
end

@doc """ Get the last available candle strictly lower than `apply(tf, date)`.

$(TYPEDSIGNATURES)

This function retrieves the last available candle (Open, High, Low, Close, Volume data for a specific time period) from the `AssetInstance` that is strictly lower than the date adjusted by the `TimeFrame` `tf`.

"""
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

@doc """ Create a similar `AssetInstance` with cash and orders reset.

$(TYPEDSIGNATURES)

This function returns a similar `AssetInstance` to the one provided, but resets the cash and orders. The limits, precision, and fees can be specified, and will default to those of the original instance.

"""
function Base.similar(
    ai::AssetInstance;
    exc=ai.exchange,
    limits=ai.limits,
    precision=ai.precision,
    fees=ai.fees,
)
    AssetInstance(ai.asset, ai.data, exc, marginmode(ai); limits, precision, fees)
end

@doc "Get the asset instance cash."
cash(ai::NoMarginInstance) = getfield(ai, :cash)
@doc "Get the asset instance cash for the long position."
cash(ai::NoMarginInstance, ::ByPos{Long}) = cash(ai)
@doc "Get the asset instance cash for the short position."
cash(ai::NoMarginInstance, ::ByPos{Short}) = 0.0
cash(ai::MarginInstance) =
    let pos = position(ai)
        isnothing(pos) && return nothing
        getfield((pos), :cash)
    end
cash(ai::MarginInstance, ::ByPos{Long}) = getfield(position(ai, Long()), :cash)
cash(ai::MarginInstance, ::ByPos{Short}) = getfield(position(ai, Short()), :cash)
@doc "Get the asset instance committed cash."
committed(ai::NoMarginInstance) = getfield(ai, :cash_committed)
committed(ai::NoMarginInstance, ::ByPos{Long}) = committed(ai)
committed(ai::NoMarginInstance, ::ByPos{Short}) = 0.0
function committed(ai::MarginInstance, ::ByPos{P}) where {P}
    getfield(position(ai, P), :cash_committed)
end
committed(ai::MarginInstance) = getfield((@something position(ai) ai), :cash_committed)
@doc "Get the asset instance ohlcv data for the smallest time frame."
ohlcv(ai::AssetInstance) = getfield(first(getfield(ai, :data)), :second)
ohlcv(ai::AssetInstance, tf::TimeFrame) = getfield(ai, :data)[tf]
@doc "Get the asset instance ohlcv data dictionary."
ohlcv_dict(ai::AssetInstance) = getfield(ai, :data)
Instruments.add!(ai::NoMarginInstance, v, args...) = add!(cash(ai), v)
Instruments.add!(ai::MarginInstance, v, p::PositionSide) = add!(cash(ai, p), v)
Instruments.sub!(ai::NoMarginInstance, v, args...) = sub!(cash(ai), v)
Instruments.sub!(ai::MarginInstance, v, p::PositionSide) = sub!(cash(ai, p), v)
Instruments.cash!(ai::NoMarginInstance, v, args...) = cash!(cash(ai), v)
Instruments.cash!(ai::MarginInstance, v, p::PositionSide) = cash!(cash(ai, p), v)
# Positive `fees_base` go `trade --> exchange`
# Negative `fees_base` go `exchange --> trade`
# When updating a position t.amount must be fee adjusted if there are (positive) fees in base currency.
# We assume the amount field in a trade is always PRE fees. So
# - If the trade amount is 1 and fees are 0.01, the cash to add (sub) to the asset will be ±0.99
# - If the trade amount is 1 and fees are -0.01 (rebates), the cash to add (sub) to the asset will be ±1.01
@doc "The amount of a trade include fees (either positive or negative)."
amount_with_fees(amt, fb) =
    if fb > 0.0 # trade --> exchange (the amount spent is the trade amount plus the base fees)
        amt - fb
    else # exchange --> trade (rebates, the amount spent is the trade amount minus the base fees (which we get back))
        amt + fb
    end
amount_with_fees(t::Trade) = amount_with_fees(t.amount, t.fees_base)
function Instruments.cash!(ai::NoMarginInstance, t::BuyTrade)
    amt = amount_with_fees(t)
    add!(cash(ai), amt)
end
@doc """ Update the cash value for a `NoMarginInstance` after a `SellTrade`.

$(TYPEDSIGNATURES)

This function updates the cash value of a `NoMarginInstance` after a `SellTrade`. The cash value would typically increase after a sell trade, as assets are sold in exchange for cash.

"""
function Instruments.cash!(ai::NoMarginInstance, t::SellTrade)
    amt = amount_with_fees(t)
    add!(cash(ai), amt)
    add!(committed(ai), amt)
end
@doc """ Update the cash value for a `MarginInstance` after an `IncreaseTrade`.

$(TYPEDSIGNATURES)

This function updates the cash value of a `MarginInstance` after an `IncreaseTrade`. The cash value would typically decrease after an increase trade, as assets are bought using cash.

"""
function Instruments.cash!(ai::MarginInstance, t::IncreaseTrade)
    amt = amount_with_fees(t)
    add!(cash(ai, positionside(t)()), amt)
end
@doc """ Update the cash value for a `MarginInstance` after a `ReduceTrade`.

$(TYPEDSIGNATURES)

This function updates the cash value of a `MarginInstance` after a `ReduceTrade`. The cash value would typically increase after a reduce trade, as assets are sold in exchange for cash.

"""
function Instruments.cash!(ai::MarginInstance, t::ReduceTrade)
    amt = amount_with_fees(t)
    add!(cash(ai, positionside(t)()), amt)
    add!(committed(ai, positionside(t)()), amt)
end
@doc """ Calculate the free cash for a `NoMarginInstance`.

$(TYPEDSIGNATURES)

This function calculates the free cash (cash that is not tied up in trades) of a `NoMarginInstance`. It takes into account the current cash, open orders, and any additional factors specified in `args`.

"""
function freecash(ai::NoMarginInstance, args...)
    ca = cash(ai) - committed(ai)
    @deassert ca |> gtxzero (cash(ai), committed(ai))
    ca
end
@doc """ Calculate the free cash for a `MarginInstance` with long position.

$(TYPEDSIGNATURES)

This function calculates the free cash (cash that is not tied up in trades) of a `MarginInstance` that has a long position. It takes into account the current cash, open long positions, and the margin requirements for those positions.

"""
function freecash(ai::MarginInstance, p::ByPos{Long})
    @deassert cash(ai, p) |> gtxzero
    @deassert committed(ai, p) |> gtxzero
    ca = max(0.0, cash(ai, p) - committed(ai, p))
    @deassert ca |> gtxzero (cash(ai, p), committed(ai, p))
    ca
end
@doc """ Calculate the free cash for a `MarginInstance` with short position.

$(TYPEDSIGNATURES)

This function calculates the free cash (cash that is not tied up in trades) of a `MarginInstance` that has a short position. It takes into account the current cash, open short positions, and the margin requirements for those positions.

"""
function freecash(ai::MarginInstance, p::ByPos{Short})
    @deassert cash(ai, p) |> ltxzero
    @deassert committed(ai, p) |> ltxzero
    ca = min(0.0, cash(ai, p) - committed(ai, p))
    @deassert ca |> ltxzero (cash(ai, p), committed(ai, p))
    ca
end
_reset!(ai) = begin
    empty!(ai.history)
    ai.lastpos[] = nothing
end
@doc """ Resets asset cash and commitments for a `NoMarginInstance`.

$(TYPEDSIGNATURES)

This function resets the cash and commitments (open trades) of a `NoMarginInstance` to initial values. Any additional arguments in `args` are used to adjust the reset process, if necessary.

"""
reset!(ai::NoMarginInstance, args...) = begin
    cash!(ai, 0.0)
    cash!(committed(ai), 0.0)
    _reset!(ai)
end
@doc """ Resets asset positions for a `MarginInstance`.

$(TYPEDSIGNATURES)

This function resets the positions (open trades) of a `MarginInstance` to initial values. Any additional arguments in `args` are used to adjust the reset process, if necessary.

"""
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

function Base.print(io::IO, ai::NoMarginInstance)
    write(io, raw(ai), "~[", compactnum(ai.cash.value), "]{", ai.exchange.name, "}")
end
function Base.print(io::IO, ai::MarginInstance)
    long = compactnum(cash(ai, Long()).value)
    short = compactnum(cash(ai, Short()).value)
    write(io, "[\"", raw(ai), "\"][L:", long, "/S:", short, "][", ai.exchange.name, "]")
end
Base.show(io::IO, ::MIME"text/plain", ai::AssetInstance) = print(io, ai)
Base.show(io::IO, ai::AssetInstance) = print(io, "\"", raw(ai), "\"")

@doc """ Stub data for an `AssetInstance` with a `DataFrame`.

$(TYPEDSIGNATURES)

This function stabs data of an `AssetInstance` with a given `DataFrame`. It's used for testing or simulating scenarios with pre-defined data.

"""
stub!(ai::AssetInstance, df::DataFrame) = begin
    tf = timeframe!(df)
    ai.data[tf] = df
end
@doc """ Calculate the value of a `NoMarginInstance`.

$(TYPEDSIGNATURES)

This function calculates the value of a `NoMarginInstance`. It uses the current price (defaulting to the last historical price), the cash in the instance and the maximum fees. The value represents the amount of cash that could be obtained by liquidating the instance at the current price, taking into account the fees.

"""
function value(
    ai::NoMarginInstance;
    current_price=lastprice(ai, Val(:history)),
    fees=current_price * cash(ai) * maxfees(ai),
)
    cash(ai) * current_price - fees
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
@doc "Get the trade history of an `AssetInstance`."
trades(ai::AssetInstance) = getfield(ai, :history)
_history_timestamp(ai) =
    let history = trades(ai)
        if isempty(history)
            DateTime(0)
        else
            last(history).date
        end
    end
@doc "Get the timestamp of the last trade."
timestamp(ai::NoMarginInstance) = _history_timestamp(ai)
timestamp(::MarginInstance, ::Nothing) = DateTime(0)
function timestamp(ai::MarginInstance, ::ByPos{P}=posside(ai)) where {P}
    pos = position(ai, P())
    if isnothing(pos)
        _history_timestamp(ai)
    else
        timestamp(pos)
    end
end
@doc "Check if an asset position is open."
function isopen(ai::MarginInstance, ::Union{Type{S},S,Position{S}}) where {S<:PositionSide}
    isopen(position(ai, S))
end
@doc "Asset position notional value."
function notional(ai::MarginInstance, ::ByPos{S}) where {S<:PositionSide}
    position(ai, S) |> notional
end
@doc "Asset entry price.

$(TYPEDSIGNATURES)
"
function price(ai::MarginInstance, fromprice, ::ByPos{S}) where {S<:PositionSide}
    v = position(ai, S) |> price
    ifelse(iszero(v), fromprice, v)
end
@doc "Asset entry price."
entryprice(ai::MarginInstance, fromprice, pos::ByPos) = price(ai, fromprice, pos)
@doc "Asset entry price.

$(TYPEDSIGNATURES)
"
price(::NoMarginInstance, fromprice, args...) = fromprice
@doc "Asset position liquidation price."
function liqprice(ai::MarginInstance, ::ByPos{S}) where {S<:PositionSide}
    position(ai, S) |> liqprice
end
@doc "Sets asset position liquidation price.

$(TYPEDSIGNATURES)
"
function liqprice!(ai::MarginInstance, v, ::ByPos{S}) where {S<:PositionSide}
    liqprice!(position(ai, S), v)
end
@doc "Asset position leverage."
function leverage(ai::MarginInstance, ::ByPos{S}=posside(ai)) where {S<:PositionSide}
    position(ai, S) |> leverage
end
leverage(::MarginInstance, ::Nothing) = 1.0
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
@doc """ Get the position tier for a `MarginInstance`.

$(TYPEDSIGNATURES)

This function returns the tier of the position for a `MarginInstance` for a given size and position side (`Long` or `Short`). The tier indicates the level of risk or capital requirement for the position.

"""
function tier(ai::MarginInstance, size, ::ByPos{S}) where {S<:PositionSide}
    tier(position(ai, S), size)
end
@doc """ Get the maintenance margin rate for a `MarginInstance`.

$(TYPEDSIGNATURES)

This function returns the maintenance margin rate for a `MarginInstance` for a given size and position side (`Long` or `Short`). The maintenance margin rate is the minimum amount of equity that must be maintained in a margin account.

"""
function mmr(ai::MarginInstance, size, s::ByPos)
    mmr(position(ai, s), size)
end
@doc """ Get the bankruptcy price for an asset position.

$(TYPEDSIGNATURES)

This function calculates the bankruptcy price, which is the price at which the asset position would be fully liquidated. It takes into account the current price of the asset and the position side (`Long` or `Short`).

"""
function bankruptcy(ai, price, ps::Type{P}) where {P<:PositionSide}
    bankruptcy(position(ai, ps), price)
end
function bankruptcy(ai, o::Order{T,A,E,P}) where {T,A,E,P<:PositionSide}
    bankruptcy(ai, o.price, P())
end

@doc """ Update the leverage for an asset position.

$(TYPEDSIGNATURES)

This function updates the leverage for a position in an asset instance. Leverage is the use of various financial instruments or borrowed capital to increase the potential return of an investment. The function takes a leverage value `v` and a position side (`Long` or `Short`) as inputs.

"""
function leverage!(ai, v, p::PositionSide)
    po = position(ai, p)
    leverage!(po, v)
    # ensure leverage tiers and limits agree
    @deassert leverage(po) <= ai.limits.leverage.max
end

@doc """ Set the leverage to maximum for a `CrossInstance`.

$(TYPEDSIGNATURES)

This function sets the leverage for a `CrossInstance` to the maximum value for the current tier. Some exchanges interpret a leverage value of 0 as max leverage in cross margin mode. This means that the maximum amount of borrowed capital will be used to increase the potential return of the investment.

"""
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

@doc """ Update the status of a hedged position in a `HedgedInstance`.

$(TYPEDSIGNATURES)

This function opens or closes the status of a hedged position in a `HedgedInstance`. A hedged position is a position that is offset by a corresponding position in a related commodity or security. The `PositionSide` and `PositionStatus` are provided as inputs.

"""
function status!(ai::HedgedInstance, p::PositionSide, pstat::PositionStatus)
    pos = position(ai, p)
    _status!(pos, pstat)
    _lastpos!(ai, p, pstat)
end

@doc """ Update the status of a non-hedged position in a `MarginInstance`.

$(TYPEDSIGNATURES)

This function opens or closes the status of a non-hedged position in a `MarginInstance`. A non-hedged position is a position that is not offset by a corresponding position in a related commodity or security. The `PositionSide` and `PositionStatus` are provided as inputs.

"""
function status!(ai::MarginInstance, p::PositionSide, pstat::PositionStatus)
    pos = position(ai, p)
    opp = opposite(ai, p)
    # HACK: the `!iszero` check is needed because in SimMode the `NewTrade` ping! in `_update_from_trade!` can trigger aditional trades
    if pstat == PositionOpen() && status(opp) == PositionOpen() && !iszero(cash(opp))
        @error "double position in non hedged mode" ai.longpos ai.shortpos
        error()
    end
    _status!(pos, pstat)
    _lastpos!(ai, p, pstat)
end

value(v::Real, args...; kwargs...) = v
@doc """ Calculate the value of a `MarginInstance`.

$(TYPEDSIGNATURES)

This function calculates the value of a `MarginInstance`. It takes into account the current price (defaulting to the price of the position), the cash in the position and the maximum fees. The value represents the amount of cash that could be obtained by liquidating the position at the current price, taking into account the fees.

"""
function value(
    ai::MarginInstance,
    ::ByPos{P}=posside(ai);
    current_price=price(position(ai, P)),
    fees=current_price * abs(cash(ai, P)) * maxfees(ai),
) where {P}
    pos = position(ai, P)
    @deassert margin(pos) > 0.0 || !isopen(pos)
    @deassert additional(pos) >= 0.0
    margin(pos) + additional(pos) + pnl(pos, current_price) - fees
end

@doc """ Calculate the profit and loss (PnL) of an asset position.

$(TYPEDSIGNATURES)

This function calculates the profit and loss (PnL) for an asset position. It takes into account the current price and the position. The PnL represents the gain or loss made on the position, based on the current price compared to the price at which the position was opened.

"""
function pnl(ai, ::ByPos{P}, price) where {P}
    pos = position(ai, P)
    isnothing(pos) && return 0.0
    pnl(pos, price)
end

@doc """ Calculate the profit and loss percentage (PnL%) of an asset position.

$(TYPEDSIGNATURES)

This function calculates the profit and loss percentage (PnL%) for an asset position in a `MarginInstance`. It takes into account the current price and the position. The PnL% represents the gain or loss made on the position, as a percentage of the investment, based on the current price compared to the price at which the position was opened.

"""
function pnlpct(ai::MarginInstance, ::ByPos{P}, price; pos=position(ai, P)) where {P}
    isnothing(pos) && return 0.0
    pnlpct(pos, price)
end
pnlpct(ai::MarginInstance, v::Number) = begin
    pos = position(ai)
    isnothing(pos) && return 0.0
    pnlpct(pos, v)
end

@doc """ Get the last price for an `AssetInstance`.

$(TYPEDSIGNATURES)

This function returns the last known price for an `AssetInstance`. Additional arguments and keyword arguments can be provided to adjust the way the last price is calculated, if necessary.

"""
function lastprice(ai::AssetInstance, args...; hist=false, kwargs...)
    exc = ai.exchange
    tickers = @tickers! markettype(exc, marginmode(ai)) false TICKERS_CACHE10
    tick = get(tickers, raw(ai), nothing)
    this_args = if isnothing(tick)
        if hist
            (ai, Val(:history))
        else
            (raw(ai), exc)
        end
    else
        (exc, tick)
    end
    lastprice(this_args...)
end
@doc """ Get the last price from the history for an `AssetInstance`.

$(TYPEDSIGNATURES)

This function returns the last known price from the historical data for an `AssetInstance`. It's useful when you need to reference the most recent historical price for calculations or comparisons.

"""
function lastprice(ai::AssetInstance, ::Val{:history})
    v = ai.history
    if length(v) > 0
        last(v).price
    else
        lastprice(ai; hist=true)
    end
end

function lastprice(ai::AssetInstance, date::DateTime)
    h = trades(ai)
    if length(h) > 0
        trade = last(h)
        if date >= trade.date
            return trade.price
        end
    end
    lastprice(ai)
end

@doc """ Get the timeframe for an `AssetInstance`.

$(TYPEDSIGNATURES)

This function returns the timeframe for an `AssetInstance`. The timeframe represents the interval at which the asset's price data is sampled or updated.

"""
function timeframe(ai::AssetInstance)
    data = getfield(ai, :data)
    if length(data) > 0
        first(keys(data))
    else
        @warn "asset: can't infer timeframe since there is not data"
        tf"1m"
    end
end

include("constructors.jl")

export AssetInstance, instance, load!, @rprice, @ramount
export asset, raw, ohlcv, ohlcv_dict, bc, qc
export takerfees, makerfees, maxfees, minfees, ishedged, isdust, nondust
export Long, Short, position, posside, cash, committed
export liqprice, leverage, bankruptcy, entryprice, price
export additional, margin, maintenance
export leverage, mmr, status!
