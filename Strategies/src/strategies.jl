using Collections: AssetCollection, Collections as coll, Instances, Data

using .Instances: AssetInstance, Position, MarginMode, PositionSide, ishedged, Instances
using .Instances: CurrencyCash, CCash
using .Instances.Exchanges
using .Instances: OrderTypes
using .OrderTypes: Order, OrderType, AnyBuyOrder, AnySellOrder, Buy, Sell, OrderSide
using .OrderTypes: OrderError, StrategyEvent, Instruments
using .Instruments: AbstractAsset, Cash, cash!, Derivatives.Derivative

import .Data: candleat, openat, highat, lowat, closeat, volumeat, closelast
using .Data: Misc
using .Data.DataFrames: nrow
using .Data.DataStructures: SortedDict, Ordering
import .Data.DataStructures: lt
using .Data: closelast
using .Misc
using .Misc: DFT, IsolatedMargin, TimeTicks, Lang
import .Misc: reset!, Long, Short, attrs
using .TimeTicks
using .Lang: @lget!
using Pkg: Pkg

abstract type AbstractStrategy end

const ExchangeAsset{E} = AssetInstance{T,E} where {T<:AbstractAsset}
const ExchangeOrder{E} = Order{O,T,E} where {O<:OrderType,T<:AbstractAsset}
const ExchangeBuyOrder{E} = AnyBuyOrder{P,T,E} where {P<:PositionSide,T<:AbstractAsset}
const ExchangeSellOrder{E} = AnySellOrder{P,T,E} where {P<:PositionSide,T<:AbstractAsset}
const PriceTime = NamedTuple{(:price, :time),Tuple{DFT,DateTime}}
struct BuyPriceTimeOrdering <: Ordering end
struct SellPriceTimeOrdering <: Ordering end
function lt(::BuyPriceTimeOrdering, a, b)
    a.price > b.price || (a.price == b.price && a.time < b.time)
end
function lt(::SellPriceTimeOrdering, a, b)
    a.price < b.price || (a.price == b.price && a.time < b.time)
end
const BuyOrdersDict{E} = SortedDict{PriceTime,ExchangeBuyOrder{E},BuyPriceTimeOrdering}
const SellOrdersDict{E} = SortedDict{PriceTime,ExchangeSellOrder{E},SellPriceTimeOrdering}

@doc """The strategy is the core type of the framework.

The strategy type is concrete according to:
- Name (Symbol)
- Exchange (ExchangeID), read from config
- Quote cash (Symbol), read from config
The exchange and the quote cash should be specified from the config, or the strategy module.

- `universe`: All the assets that the strategy knows about
- `holdings`: assets with non zero balance.
- `buyorders`: active buy orders
- `sellorders`: active sell orders
- `timeframe`: the smallest timeframe the strategy uses
- `cash`: the quote currency used for trades
- `cash_committed`: cash kept busy by pending orders
- `config`: The `Config` the strategy was instantiated with.
- `logs`: logs exchange events like positions updates.

Conventions for strategy defined attributes:
- `DESCRIPTION`: Name or short description for the strategy could be different from module name
- `S`: the strategy type.
- `TF`: the smallest `timeframe` that the strategy uses
"""
struct Strategy{X<:ExecMode,N,E<:ExchangeID,M<:MarginMode,C} <: AbstractStrategy
    self::Module
    config::Config
    timeframe::TimeFrame
    cash::CCash{E}{C}
    cash_committed::CCash{E}{C}
    buyorders::Dict{ExchangeAsset{E},BuyOrdersDict{E}}
    sellorders::Dict{ExchangeAsset{E},SellOrdersDict{E}}
    holdings::Set{ExchangeAsset{E}}
    universe::AssetCollection
    logs::Vector{StrategyEvent{E}}
    lock::ReentrantLock
    function Strategy(
        self::Module,
        mode::ExecMode,
        margin::MarginMode,
        timeframe::TimeFrame,
        exc::Exchange,
        uni::AssetCollection;
        config::Config
    )
        @assert !ishedged(margin) "Hedged margin not yet supported."
        ca = CurrencyCash(exc, config.qc, config.initial_cash)
        if !coll.iscashable(ca, uni)
            @warn "Assets within the strategy universe don't match the strategy cash! ($(nameof(ca)))"
        end
        _no_inv_contracts(exc, uni)
        ca_comm = CurrencyCash(exc, config.qc, 0.0)
        eid = typeof(exc.id)
        if issandbox(exc) && mode isa Paper
            @warn "Exchange should not be in sandbox mode if strategy is in paper mode."
        end
        holdings = Set{ExchangeAsset{eid}}()
        buyorders = Dict{ExchangeAsset{eid},SortedDict{PriceTime,ExchangeBuyOrder{eid}}}()
        sellorders = Dict{ExchangeAsset{eid},SortedDict{PriceTime,ExchangeSellOrder{eid}}}()
        name = nameof(self)
        # set exchange
        exc.options["defaultMarginMode"] = margin isa IsolatedMargin ? "isolated" : "cross"
        setattr!(config, exc, :exc)
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
            ReentrantLock(),
        )
    end
end

# NOTE: it's possible these should be functors to avoid breaking Revise
const SimStrategy = Strategy{Sim}
const PaperStrategy = Strategy{Paper}
const LiveStrategy = Strategy{Live}
@doc "Real time strategy."
const RTStrategy = Strategy{<:Union{Paper,Live}}
const IsolatedStrategy = Strategy{X,N,<:ExchangeID,Isolated,C} where {X<:ExecMode,N,C}
const CrossStrategy = Strategy{X,N,<:ExchangeID,Cross,C} where {X<:ExecMode,N,C}
const MarginStrategy =
    Strategy{X,N,<:ExchangeID,<:Union{Isolated,Cross},C} where {X<:ExecMode,N,C}
const NoMarginStrategy = Strategy{X,N,<:ExchangeID,NoMargin,C} where {X<:ExecMode,N,C}
@doc "Functions that are called (with the strategy as argument) right after strategy construction."
const STRATEGY_LOAD_CALLBACKS = (; (m => Function[] for m in (:sim, :paper, :live))...)

include("methods.jl")
include("interface.jl")
include("load.jl")
include("utils.jl")
include("print.jl")
include("forward.jl")

export Strategy, strategy, strategy!, reset!, default!
export @interface, assets, exchange, universe, throttle, marketsid
export LoadStrategy, ResetStrategy, WarmupPeriod, StrategyMarkets
export SimStrategy, PaperStrategy, LiveStrategy, RTStrategy, IsolatedStrategy, CrossStrategy
export attr, attrs, setattr!
export issim, ispaper, islive
