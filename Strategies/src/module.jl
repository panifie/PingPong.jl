using Collections: AssetCollection, Collections as coll, Instances, Data

using .Instances: AssetInstance, Position, MarginMode, PositionSide, ishedged, Instances
using .Instances: CurrencyCash, CCash
using .Instances.Exchanges
using .Instances: OrderTypes
using .OrderTypes: Order, OrderType, AnyBuyOrder, AnySellOrder, Buy, Sell, OrderSide
using .OrderTypes: OrderError, StrategyEvent, Instruments
using .Instruments: AbstractAsset, Cash, cash!, Derivatives.Derivative

import .Data: candleat, openat, highat, lowat, closeat, volumeat, closelast
using .Data: Misc, EventTrace
using .Data.DataFrames: nrow
using .Data.DataStructures: SortedDict, Ordering
import .Data.DataStructures: lt
using .Data: closelast
using .Misc
using .Misc: DFT, IsolatedMargin, TimeTicks, Lang
import .Misc: reset!, Long, Short, attrs, ping!, pong!
using .TimeTicks
using .Lang: @lget!
using Pkg: Pkg

@doc "The base type for all strategies."
abstract type AbstractStrategy end

@doc "`AssetInstance` by `ExchangeID`"
const ExchangeAsset{E} = AssetInstance{T,E} where {T<:AbstractAsset}
@doc "`Order` by `ExchangeID`"
const ExchangeOrder{E} = Order{O,T,E} where {O<:OrderType,T<:AbstractAsset}
@doc "`BuyOrder` by `ExchangeID`"
const ExchangeBuyOrder{E} = AnyBuyOrder{P,T,E} where {P<:PositionSide,T<:AbstractAsset}
@doc "`SellOrder` by `ExchangeID`"
const ExchangeSellOrder{E} = AnySellOrder{P,T,E} where {P<:PositionSide,T<:AbstractAsset}
@doc "`PriceTime` named tuple"
const PriceTime = NamedTuple{(:price, :time),Tuple{DFT,DateTime}}
@doc "Ordering for buy orders (highest price first)"
struct BuyPriceTimeOrdering <: Ordering end
@doc "Ordering for sell orders (lowest price first)"
struct SellPriceTimeOrdering <: Ordering end
function lt(::BuyPriceTimeOrdering, a, b)
    a.price > b.price || (a.price == b.price && a.time < b.time)
end
function lt(::SellPriceTimeOrdering, a, b)
    a.price < b.price || (a.price == b.price && a.time < b.time)
end
@doc "`SortedDict` of holding buy orders"
const BuyOrdersDict{E} = SortedDict{PriceTime,ExchangeBuyOrder{E},BuyPriceTimeOrdering}
@doc "`SortedDict` of holding sell orders"
const SellOrdersDict{E} = SortedDict{PriceTime,ExchangeSellOrder{E},SellPriceTimeOrdering}

@doc """The strategy is the core type of the framework.

$(FIELDS)

The strategy type is concrete according to:
- Name (Symbol)
- Exchange (ExchangeID), read from config
- Quote cash (Symbol), read from config
- Margin mode (MarginMode), read from config
- Execution mode (ExecMode), read from config

Conventions for strategy defined attributes:
- `S`: the strategy type.
- `SC`: the strategy type (exchange generic).
- `TF`: the smallest `timeframe` that the strategy uses
- `DESCRIPTION`: Name or short description for the strategy could be different from module name
"""
struct Strategy{X<:ExecMode,N,E<:ExchangeID,M<:MarginMode,C} <: AbstractStrategy
    "The strategy module"
    self::Module
    "The `Config` the strategy was instantiated with"
    config::Config
    "The smallest timeframe the strategy uses"
    timeframe::TimeFrame
    "The quote currency used for trades"
    cash::CCash{E}{C}
    "Cash kept busy by pending orders"
    cash_committed::CCash{E}{C}
    "Active buy orders"
    buyorders::Dict{ExchangeAsset{E},BuyOrdersDict{E}}
    "Active sell orders"
    sellorders::Dict{ExchangeAsset{E},SellOrdersDict{E}}
    "Assets with non zero balance"
    holdings::Set{ExchangeAsset{E}}
    "All the assets that the strategy knows about"
    universe::AssetCollection
    "A lock for thread safety"
    lock::ReentrantLock
    @doc """ Initializes a new `Strategy` object

    $(TYPEDSIGNATURES)

    This function takes a module, execution mode, margin mode, timeframe, exchange, and asset collection to create a new `Strategy` object. 
    It also accepts a `config` object to set specific parameters. 
    The function validates the universe of assets and the strategy's cash, sets the exchange, and initializes orders and holdings. 

    """
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
        if !isempty(uni) && !coll.iscashable(ca, uni)
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
        mm = margin isa IsolatedMargin ? "isolated" : "cross"
        marginmode!(exc, mm, "")
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
            ReentrantLock(),
        )
    end
end

# NOTE: it's possible these should be functors to avoid breaking Revise
@doc "Simulation strategy."
const SimStrategy = Strategy{Sim}
@doc "Paper trading strategy."
const PaperStrategy = Strategy{Paper}
@doc "Live trading strategy."
const LiveStrategy = Strategy{Live}
@doc "Real time strategy (`Paper`, `Live`)."
const RTStrategy = Strategy{<:Union{Paper,Live}}
@doc "Isolated margin strategy."
const IsolatedStrategy = Strategy{X,N,<:ExchangeID,Isolated,C} where {X<:ExecMode,N,C}
@doc "Cross margin strategy."
const CrossStrategy = Strategy{X,N,<:ExchangeID,Cross,C} where {X<:ExecMode,N,C}
@doc "Strategy with isolated or cross margin."
const MarginStrategy =
    Strategy{X,N,<:ExchangeID,<:Union{Isolated,Cross},C} where {X<:ExecMode,N,C}
@doc "Strategy with no margin at all."
const NoMarginStrategy = Strategy{X,N,<:ExchangeID,NoMargin,C} where {X<:ExecMode,N,C}
@doc "Functions that are called (with the strategy as argument) right after strategy construction."
const STRATEGY_LOAD_CALLBACKS = (; (m => Function[] for m in (:sim, :paper, :live))...)

include("methods.jl")
include("interface.jl")
include("load.jl")
include("utils.jl")
include("print.jl")

export Strategy, strategy, strategy!, reset!, default!
export @interface, assets, exchange, universe, throttle, marketsid
export LoadStrategy, ResetStrategy, WarmupPeriod, StrategyMarkets
export SimStrategy, PaperStrategy, LiveStrategy, RTStrategy, IsolatedStrategy, CrossStrategy
export attr, attrs, setattr!
export issim, ispaper, islive
