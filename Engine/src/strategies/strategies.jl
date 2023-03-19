module Strategies
using Pkg: Pkg
using TimeTicks
using ExchangeTypes
using Exchanges: getexchange!
using Misc
using Data.DataFrames: nrow
using Instruments: AbstractAsset, Cash, cash!
using ..Types
using ..Types.Collections: AssetCollection
using ..Types.Instances: AssetInstance
using ..Types.Orders: Order, OrderType
using ..Engine: Engine

abstract type AbstractStrategy end

ExchangeAsset{E} = AssetInstance{T,E} where {T<:AbstractAsset}
ExchangeOrder{E} = Order{O,T,E} where {O<:OrderType,T<:AbstractAsset}
# TYPENUM
struct Strategy64{M<:ExecMode,S,E<:ExchangeID} <: AbstractStrategy
    self::Module
    config::Config
    timeframe::TimeFrame
    cash::Cash{S,Float64} where {S}
    cash_committed::Cash{S,Float64} where {S}
    orders::Dict{ExchangeAsset{E},Vector{ExchangeOrder{E}}}
    holdings::Set{ExchangeAsset{E}}
    universe::AssetCollection
    function Strategy64(
        self::Module, mode=Sim; assets::Union{Dict,Iterable{String}}, config::Config
    )
        exc = getexchange!(config.exchange)
        timeframe = @something self.TF config.min_timeframe first(config.timeframes)
        uni = AssetCollection(assets; timeframe=string(timeframe), exc)
        ca = Cash(config.qc, config.initial_cash)
        ca_comm = Cash(config.qc, 0.0)
        eid = typeof(exc.id)
        holdings = Set{ExchangeAsset{eid}}()
        orders = Dict{ExchangeAsset,Vector{ExchangeOrder{eid}}}()
        name = nameof(self)
        new{mode,name,eid}(self, config, timeframe, ca, ca_comm, orders, holdings, uni)
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
Strategy = Strategy64

@doc "Resets strategy."
reset!(s::Strategy) = begin
    empty!(s.orders)
    empty!(s.holdings)
    for ai in s.universe
        empty!(ai.history)
        cash!(ai.cash, 0.0)
        cash!(ai.cash_committed, 0.0)
    end
    cash!(s.cash, s.config.initial_cash)
    cash!(s.cash_committed, 0.0)
end
@doc "Reloads ohlcv data for assets already present in the strategy universe."
reload!(s::Strategy) = begin
    for inst in s.universe.data.instance
        empty!(inst.data)
        load!(inst; reset=true)
    end
end

@doc "Assets loaded by the strategy."
assets(s::Strategy) = s.universe.data.asset
@doc "Strategy assets instance."
instances(s::Strategy) = s.universe.data.instance
@doc "Strategy main exchange id."
exchange(t::Type{<:Strategy}) = t.parameters[3].parameters[1]

@doc "Returns the strategy execution mode."
Misc.execmode(::Strategy{M}) where {M<:ExecMode} = M()

@doc "Creates a context within the available data loaded into the strategy universe with the smallest timeframe available."
Types.Context(s::Strategy{<:ExecMode}) = begin
    dr = DateRange(s.universe)
    Types.Context(execmode(s), dr)
end

## Strategy interface
@doc "Called on each timestep iteration, possible multiple times.
Receives:
- `current_time`: the current timestamp to evaluate (the current candle would be `current_time - timeframe`).
- `ctx`: The context of the executor.
"
ping!(::Strategy, current_time, ctx, args...; kwargs...) = error("Not implemented")
const evaluate! = ping!
struct LoadStrategy <: ExecAction end
@doc "Called to construct the strategy, should return the strategy instance."
ping!(::Type{<:Strategy}, ::LoadStrategy, ctx) = nothing
struct WarmupPeriod <: ExecAction end
@doc "How much lookback data the strategy needs."
ping!(s::Strategy, ::WarmupPeriod) = s.timeframe.period

macro interface()
    quote
        import Engine.Strategies: ping!, evaluate!
        using Engine.Strategies: assets, exchange
        using Engine: pong!, execute!
    end
end

macro notfound(path)
    quote
        throw(LoadError("Strategy not found at $(esc(file))"))
    end
end

function find_path(file, cfg)
    if !ispath(file)
        if isabspath(file)
            @notfound file
        else
            from_pwd = joinpath(pwd(), file)
            ispath(from_pwd) && return from_pwd
            from_cfg = joinpath(dirname(cfg.path), file)
            ispath(from_cfg) && return from_cfg
            from_proj = joinpath(dirname(Pkg.project().path), file)
            ispath(from_proj) && return from_proj
            @notfound file
        end
    end
    realpath(file)
end

Base.nameof(t::Type{<:Strategy}) = t.parameters[2]
Base.nameof(s::Strategy) = nameof(typeof(s))

@doc "Set strategy defaults."
default!(::Strategy) = begin end

function loadstrategy!(src::Symbol, cfg=config)
    file = get(cfg.sources, src, nothing)
    if isnothing(file)
        throw(ArgumentError("Symbol $src not found in config $(config.path)."))
    end
    path = find_path(file, cfg)
    mod = if !isdefined(@__MODULE__, src)
        @eval begin
            if isdefined(Main, :Revise)
                @eval Main begin
                    Revise.includet($path)
                    using Main.$src
                    Main.$src
                end
            else
                include($path)
                using .$src
                $src
            end
        end
    else
        if isdefined(Main, :Revise)
            Core.eval(Main, src)
        else
            @eval $src
        end
    end
    loadstrategy!(mod, cfg)
end
function loadstrategy!(mod::Module, cfg=config)
    strat_exc = exchange(mod.S{typeof(config.mode)})
    # The strategy can have a default exchange symbol
    if cfg.exchange == Symbol()
        cfg.exchange = strat_exc
    end
    @assert cfg.exchange == strat_exc "Config exchange $(cfg.exchange) doesn't match strategy exchange! $(strat_exc)"
    @assert nameof(mod.S) isa Symbol "Source $src does not define a strategy name."
    invokelatest(mod.ping!, mod.S, LoadStrategy(), cfg)
end

include("utils.jl")
include("print.jl")

export Strategy, loadstrategy!, reset!
export @interface, assets, exchange
export LoadStrategy, WarmupPeriod

end
