module Strategies
using Pkg: Pkg
using TimeTicks
using ExchangeTypes
using Exchanges: getexchange!
using Misc
using Instruments: AbstractAsset, Cash
using ..Types
using ..Types.Collections: AssetCollection
using ..Types.Instances: AssetInstance
using ..Types.Orders: Order, OrderType
using ..Engine: Engine

abstract type AbstractStrategy end

const ExchangeAsset{E} = AssetInstance{AbstractAsset,E}
const ExchangeOrder{E} = Order{OrderType,AbstractAsset,E}
# TYPENUM
struct Strategy56{M<:ExecMode,S,E<:ExchangeID} <: AbstractStrategy
    self::Module
    universe::AssetCollection
    holdings::Dict{AbstractAsset,ExchangeAsset{E}}
    orders::Dict{AbstractAsset,Vector{ExchangeOrder{E}}}
    timeframe::TimeFrame
    cash::Cash
    config::Config
    function Strategy56(
        self::Module, mode=Sim; assets::Union{Dict,Iterable{String}}, config::Config
    )
        exc = getexchange!(config.exchange)
        timeframe = @something self.TF config.base_timeframe first(config.timeframes)
        uni = AssetCollection(assets; timeframe=string(timeframe), exc)
        ca = Cash(config.qc, config.initial_cash)
        eid = typeof(exc.id)
        holdings = Dict{AbstractAsset,ExchangeAsset{eid}}()
        orders = Dict{AbstractAsset,Vector{ExchangeOrder{eid}}}()
        name = nameof(self)
        new{mode,name,eid}(self, uni, holdings, orders, timeframe, ca, config)
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
Strategy = Strategy56

@doc "Clears all orders history from strategy."
resethistory!(strat::Strategy) = begin
    empty!(strat.orders)
    for inst in strat.universe.data.instance
        empty!(inst.history)
    end
end
@doc "Reloads ohlcv data for assets already present in the strategy universe."
reload!(strat::Strategy) = begin
    for inst in strat.universe.data.instance
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

@doc "Creates a context within the available data loaded into the strategy universe with the smallest timeframe available."
Types.Context(s::Strategy) = begin
    dr = DateRange(s.universe)
    Types.Context(dr)
end

## Strategy interface
@doc "Called on each timestep iteration, possible multiple times.
Receives:
- `current_time`: the current timestamp to evaluate (the current candle would be `current_time - timeframe`).
- `ctx`: The context of the executor.
"
ping!(::Strategy, current_time, ctx, args...; kwargs...) = error("Not implemented")
const evaluate! = ping!
@doc "Called to construct the strategy, should return the strategy instance."
load(::Type{<:Strategy}) = nothing
@doc "How much lookback data the strategy needs. Used for backtesting."
warmup(s::Strategy) = s.timeframe.period

macro interface()
    quote
        import Engine.Strategies: ping!, evaluate!, load, warmup
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

Base.nameof(t::Type{Strategy}) = t.parameters[1]
Base.nameof(s::Strategy) = name(typeof(s))

function loadstrategy!(src::Symbol, cfg=config)
    file = get(cfg.sources, src, nothing)
    if isnothing(file)
        throw(ArgumentError("Symbol $src not found in config $(config.path)."))
    end
    path = find_path(file, cfg)
    mod = if !isdefined(@__MODULE__, src)
        @eval begin
            include($path)
            using .$src
            if isdefined(Main, :Revise)
                Core.eval(Main, :(Revise.track($$src)))
            end
            $src
        end
    else
        @eval $src
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
    invokelatest(mod.load, mod.S, cfg)
end

function Base.show(out::IO, strat::Strategy)
    write(out, "Strategy name: $(typeof(strat))\n")
    write(out, "Base Amount: $(strat.config.base_amount)\n")
    n_inst = nrow(strat.universe)
    n_exc = length(unique(strat.universe.exchange))
    write(out, "Universe: $n_inst instances, $n_exc exchanges")
    write(out, "\n")
    balance = isempty(strat.holdings) ? 0 : sum(a.cash for a in values(strat.holdings))
    write(out, "Holdings: $balance \n")
    write(out, "\n")
    write(out, "Orders:\n")
    write(out, string(strat.orders))
end

export Strategy, loadstrategy!, resethistory!
export @interface, assets, exchange

end
