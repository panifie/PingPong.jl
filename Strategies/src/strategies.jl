using Collections: AssetCollection, Collections as coll

using Instances: AssetInstance, Position, MarginMode, PositionSide
using OrderTypes: Order, OrderType, BuyOrder, SellOrder, Buy, Sell, OrderSide
using OrderTypes: OrderError, StrategyEvent
using ExchangeTypes
using TimeTicks
using Instruments
using Instruments: AbstractAsset, Cash, cash!, Derivatives.Derivative

import Data: candleat, openat, highat, lowat, closeat, volumeat, closelast
using Data.DataFrames: nrow
using Data: closelast
using Misc
using Misc: DFT
using Lang: @lget!
using Pkg: Pkg

abstract type AbstractStrategy end

const ExchangeAsset{E} = AssetInstance{T,E} where {T<:AbstractAsset}
const ExchangeOrder{E} = Order{O,T,E} where {O<:OrderType,T<:AbstractAsset}
const ExchangeBuyOrder{E} = BuyOrder{T,E} where {T<:AbstractAsset}
const ExchangeSellOrder{E} = SellOrder{T,E} where {T<:AbstractAsset}

@doc """The strategy is the core type of the framework.

The strategy type is concrete according to:
- Name (Symbol)
- Exchange (ExchangeID), read from config
- Quote cash (Symbol), read from config
The exchange and the quote cash should be specified from the config, or the strategy module.

- `universe`: All the assets that the strategy knows about
- `holdings`: assets with non zero balance.
- `orders`: active orders
- `timeframe`: the smallest timeframe the strategy uses
- `cash`: the quote currency used for trades

Conventions for strategy defined attributes:
- `NAME`: the name of the strategy could be different from module name
- `S`: the strategy type.
- `TF`: the smallest `timeframe` that the strategy uses
"""
struct Strategy{X<:ExecMode,N,E<:ExchangeID,M<:MarginMode,C} <: AbstractStrategy
    self::Module
    config::Config
    timeframe::TimeFrame
    cash::Cash{C,DFT}
    cash_committed::Cash{C,DFT}
    buyorders::Dict{ExchangeAsset{E},Set{ExchangeBuyOrder{E}}}
    sellorders::Dict{ExchangeAsset{E},Set{ExchangeSellOrder{E}}}
    holdings::Set{ExchangeAsset{E}}
    universe::AssetCollection
    logs::Vector{StrategyEvent{E}}
    function Strategy(
        self::Module,
        mode::ExecMode,
        margin::MarginMode,
        timeframe::TimeFrame,
        exc::Exchange,
        uni::AssetCollection;
        config::Config,
    )
        ca = Cash(config.qc, config.initial_cash)
        if !coll.iscashable(ca, uni)
            @warn "Assets within the strategy universe don't match the strategy cash! ($(nameof(ca)))"
        end
        ca_comm = Cash(config.qc, 0.0)
        eid = typeof(exc.id)
        holdings = Set{ExchangeAsset{eid}}()
        buyorders = Dict{ExchangeAsset{eid},Set{ExchangeBuyOrder{eid}}}()
        sellorders = Dict{ExchangeAsset{eid},Set{ExchangeSellOrder{eid}}}()
        name = nameof(self)
        new{typeof(mode),name,eid,typeof(margin),config.qc}(
            self,
            config,
            timeframe,
            ca,
            ca_comm,
            buyorders,
            sellorders,
            holdings,
            uni,
            StrategyEvent{eid}[],
        )
    end
end

# NOTE: it's possible these should be functors to avoid breaking Revise
const SimStrategy{N,E<:ExchangeID,M<:MarginMode} = Strategy{Sim,N,E,M}
const PaperStrategy{N,E<:ExchangeID,M<:MarginMode} = Strategy{Paper,N,E,M}
const LiveStrategy{N,E<:ExchangeID,M<:MarginMode} = Strategy{Live,N,E,M}
const IsolatedStrategy{X<:ExecMode,N,E<:ExchangeID} = Strategy{X,N,E,Isolated}
const CrossStrategy{X<:ExecMode,N,E<:ExchangeID} = Strategy{X,N,E,Cross}
const MarginStrategy{X,N,E,M<:Union{Isolated,Cross}} = Strategy{X,N,E,M}
const NoMarginStrategy{X,N,E} = Strategy{X,N,E,NoMargin}

include("methods.jl")
include("interface.jl")
include("load.jl")
include("utils.jl")
include("print.jl")

export Strategy, strategy, strategy!, reset!
export @interface, assets, exchange
export LoadStrategy, WarmupPeriod
export SimStrategy, PaperStrategy, LiveStrategy, IsolatedStrategy, CrossStrategy
