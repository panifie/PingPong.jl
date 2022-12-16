using Dates: DateTime
using Misc: Candle, PairData, TimeFrame, exc, Exchange, convert
using Pairs: Asset
using Exchanges: load_pairs, getexchange!
using Data: load_pair, zi
using DataFrames: DataFrame

include("consts.jl")
include("funcs.jl")

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


@doc "The state against which a strategy is tested."
struct Context
    data::Dict{String,PairData}
    from_date::DateTime
    to_date::DateTime
    amount::Float64
    Context(data, from_date, to_date, buyfn, sellfn) = begin
        new(data, from_date, to_date, buyfn, sellfn)
    end
    Context(data, from_date, to_date, buyfn) = begin
        new(data, from_date, to_date, buyfn, nosignal)
    end
end


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
    Trade(candle=candle, signal=sig, price=price, amount=amount)
end

export create_trade

@doc "An asset instance holds all known state about an asset, i.e. `BTC/USDT`:
- `asset`: the identifier
- `data`: ohlcv series
- `history`: the trade history of the pair
- `cash`: how much is currently held, can be positive or negative (short)
- `exchange`: the exchange instance that this asset instance belongs to.
"
struct AssetInstance{T<:Asset}
    asset::T
    data::Dict{<:TimeFrame,DataFrame}
    history::Vector{Trade{T}}
    cash::Float64
    exchange::Ref{Exchange}
    AssetInstance(a::T, data, e::Exchange) where {T<:Asset} = begin
        new{typeof(a)}(a, data, Trade{T}[], 0., e)
    end
    AssetInstance(s::S, t::S, e::S) where {S<:AbstractString} = begin
        a = Asset(s)
        tf = convert(TimeFrame, t)
        exc = getexchange!(Symbol(e))
        data = Dict(tf => load_pair(zi, exc, a.raw, t))
        AssetInstance(a, data, exc)
    end
    AssetInstance(s, t) = AssetInstance(s, t, exc)
end

@doc "A collection of assets instances."
const Portfolio = Dict{Asset, AssetInstance}

function portfolio(instances::Vector{<:AssetInstance})::Portfolio
    Portfolio(a.asset => a for a in instances)
end

function portfolio(assets::Union{Vector{String}, Vector{<:Asset}}; timeframe = "15m", exc::Exchange = exc)::Portfolio
    pf = Portfolio()
    if assets isa Vector{String}
        getAsset(name::String) = Asset(name)
    else
        getAsset(name::Asset) = identity(name)
    end
    for a in assets
        ast = getAsset(a)
        tf = convert(TimeFrame, timeframe)
        data = Dict(tf => load_pair(zi, exc.name, ast.raw, tf))
        pf[ast] = AssetInstance(ast, data, exc)
    end
    pf
end

# function portfolio(names::Vector{String}; timeframe = "15m", exc::Exchange = exc)
#     for name in names
#         asset = Asset(name)
#         pf[asset] = AssetInstance(asset, timeframe, exc)
#     end
# end

export Portfolio, portfolio

@doc """The strategy is the core type of the framework.
- buyfn: (Cursor, Data) -> Order
- sellfn: Same as buyfn but for selling
- base_amount: The minimum size of an order
"""
struct Strategy
    buyfn::Function
    sellfn::Function
    portfolio::Portfolio
    base_amount::Float64
end
