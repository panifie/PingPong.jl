using Dates: DateTime
using Base: dotgetproperty
using Misc: Candle, PairData, TimeFrame, convert
using Pairs: Asset
using ExchangeTypes
using Exchanges:
    load_pairs,
    getexchange!,
    is_pair_active,
    pair_fees,
    pair_min_size,
    pair_precision,
    get_pairs
using Data: load_pair, zi
using DataFrames: DataFrame

include("consts.jl")
include("funcs.jl")

const Iterable10 = Union{AbstractVector{T},AbstractSet{T}} where {T}
Iterable = Iterable10

@enum BuySignal begin
    Buy
    LadderBuy
    RebalanceBuy
end

@enum SellSignal begin
    Sell
    StopLoss
    TakeProfit
    TrailingStop
    TrailingProfit
    LadderSell
    RebalanceSell
end

@doc "An type to specify the reason why a buy or sell event has happened."
const Signal = Union{BuySignal,SellSignal}

@doc """The configuration against which a strategy is tested.
- `spread`: affects the weight of the spread calculation (based on ohlcv)."
- `slippage`: affects the weight of the spread calculation (based on volume and trade size).
"""
struct Context3
    from_date::DateTime
    to_date::DateTime
    spread::Float64
    slippage::Float64
    Context(from_date, to_date) = begin
        new(from_date, to_date, 1.0, 1.0)
    end
end
Context = Context3

@doc "Buy or Sell? And how much?"
const Order = @NamedTuple{signal::Signal, amount::Float64}

@doc """ A buy or sell event that has happened.
- order: The order received by the strategy
- price: The actual price of execution (accounting for spread)
- amount: The actual amount of the finalized trade (accounting for fees)
"""
struct Trade{T<:Asset}
    pair::T
    candle::Candle
    date::DateTime
    order::Order
    price::Float64
    amount::Float64
end

function create_trade(candle::Candle, sig::Signal, price, amount)
    Trade(; candle=candle, signal=sig, price=price, amount=amount)
end

export create_trade

@doc "An asset instance holds all known state about an asset, i.e. `BTC/USDT`:
- `asset`: the identifier
- `data`: ohlcv series
- `history`: the trade history of the pair
- `cash`: how much is currently held, can be positive or negative (short)
- `exchange`: the exchange instance that this asset instance belongs to.
- `minsize`: minimum order size (from exchange)
- `precision`: number of decimal points (from exchange)
"
struct AssetInstance11{T<:Asset}
    asset::T
    data::Dict{<:TimeFrame,DataFrame}
    history::Vector{Trade{T}}
    cash::Vector{Float64}
    exchange::Ref{Exchange}
    minsize::NamedTuple{(:b, :q),NTuple{2,Float64}}
    precision::NamedTuple{(:b, :q),NTuple{2,UInt8}}
    fees::Float64
    AssetInstance11(a::T, data, e::Exchange) where {T<:Asset} = begin
        minsize = pair_min_size(a.raw, e)
        precision = pair_precision(a.raw, e)
        fees = pair_fees(a.raw, e)
        new{typeof(a)}(a, data, Trade{T}[], Float64[0], e, minsize, precision, fees)
    end
    AssetInstance11(s::S, t::S, e::S) where {S<:AbstractString} = begin
        a = Asset(s)
        tf = convert(TimeFrame, t)
        exc = getexchange!(Symbol(e))
        data = Dict(tf => load_pair(zi, exc.name, a.raw, t))
        AssetInstance11(a, data, exc)
    end
    AssetInstance11(s, t) = AssetInstance11(s, t, exc)
end
AssetInstance = AssetInstance11

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
export getproperty, setproperty!

include("portfolio.jl")

@doc """The strategy is the core type of the framework.
- buyfn: (Cursor, Data) -> Order
- sellfn: Same as buyfn but for selling
- base_amount: The minimum size of an order
"""
struct Strategy5
    buyfn::Function
    sellfn::Function
    pf::Portfolio
    base_amount::Float64
    Strategy5(assets::Iterable{String}) = begin
        pf = Portfolio(assets)
        new(x -> false, x -> false, pf, 10.0)
    end
    Strategy5() = begin
        Strategy5(get_pairs())
    end
end
Strategy = Strategy5

export AssetInstance, Strategy
