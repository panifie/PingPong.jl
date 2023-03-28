module Strategies
using Pkg: Pkg
using TimeTicks
using ExchangeTypes
using Exchanges: getexchange!
using Misc
using Data.DataFrames: nrow
using Instruments: AbstractAsset, Cash, cash!
using ..Types
using ..Types.Collections: AssetCollection, Collections as coll
using ..Types.Instances: AssetInstance
using ..Types.Orders: Order, OrderType
using ..Engine: Engine

abstract type AbstractStrategy end

ExchangeAsset(E) = AssetInstance{T,E} where {T<:AbstractAsset}
ExchangeOrder(E) = Order{O,T,E} where {O<:OrderType,T<:AbstractAsset}
ExchangeBuyOrder(E) = BuyOrder{O,T,E} where {O<:OrderType,T<:AbstractAsset}
ExchangeSellOrder(E) = SellOrder{O,T,E} where {O<:OrderType,T<:AbstractAsset}
# TYPENUM
struct Strategy69{M<:ExecMode,S,E<:ExchangeID} <: AbstractStrategy
    self::Module
    config::Config
    timeframe::TimeFrame
    cash::Cash{S1,Float64} where {S1}
    cash_committed::Cash{S2,Float64} where {S2}
    buyorders::Dict{ExchangeAsset(E),Set{ExchangeBuyOrder(E)}}
    sellorders::Dict{ExchangeAsset(E),Set{ExchangeSellOrder(E)}}
    holdings::Set{ExchangeAsset(E)}
    universe::AssetCollection
    function Strategy69(
        self::Module, mode=Sim; assets::Union{Dict,Iterable{String}}, config::Config
    )
        exc = getexchange!(config.exchange)
        timeframe = @something self.TF config.min_timeframe first(config.timeframes)
        uni = AssetCollection(assets; timeframe=string(timeframe), exc)
        ca = Cash(config.qc, config.initial_cash)
        if !coll.iscashable(ca, uni)
            @warn "Assets within the strategy universe don't match the strategy cash! ($(nameof(ca)))"
        end
        ca_comm = Cash(config.qc, 0.0)
        eid = typeof(exc.id)
        holdings = Set{ExchangeAsset(eid)}()
        buyorders = Dict{ExchangeAsset(eid),Set{ExchangeBuyOrder(eid)}}()
        sellorders = Dict{ExchangeAsset(eid),Set{ExchangeSellOrder(eid)}}()
        name = nameof(self)
        new{mode,name,eid}(
            self, config, timeframe, ca, ca_comm, buyorders, sellorders, holdings, uni
        )
    end
end
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
Strategy = Strategy69

include("methods.jl")
include("interface.jl")
include("load.jl")
include("utils.jl")
include("print.jl")

export Strategy, strategy, strategy!, reset!
export @interface, assets, exchange
export LoadStrategy, WarmupPeriod

end
