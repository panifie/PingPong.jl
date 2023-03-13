module Strategies
using Pkg: Pkg
using ExchangeTypes
using Exchanges: getexchange!
using Misc: Config, config, Iterable
using Data: Candle
using Instruments: Asset, Cash
using ..Collections
using ..Instances
using ..Orders
using ..LiveOrders
using ..Engine
using Instruments
using TimeTicks

const ExchangeAsset{E} = AssetInstance{AbstractAsset,E}
const ExchangeOrder{E} = Order{OrderType,AbstractAsset,E}
# TYPENUM
struct Strategy54{M,E<:ExchangeID}
    mod::Module
    universe::AssetCollection
    holdings::Dict{AbstractAsset,ExchangeAsset{E}}
    orders::Dict{AbstractAsset,Vector{ExchangeOrder{E}}}
    timeframe::TimeFrame
    cash::Cash
    config::Config
    function Strategy54(mod::Module, assets::Union{Dict,Iterable{String}}, config::Config)
        exc = getexchange!(config.exchange)
        uni = AssetCollection(assets; exc)
        ca = Cash(config.qc, config.initial_cash)
        eid = typeof(exc.id)
        holdings = Dict{AbstractAsset,ExchangeAsset{eid}}()
        orders = Dict{AbstractAsset,Vector{ExchangeOrder{eid}}}()
        name = nameof(mod)
        timeframe = @something mod.TF config.timeframe first(config.timeframes)
        new{name,eid}(mod, uni, holdings, orders, timeframe, ca, config)
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
- `EXCID`: same as `exchange(S)`
- `TF`: the smallest `timeframe` that the strategy uses
"""
Strategy = Strategy54

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

@doc "Creates a context within the available data loaded into the strategy universe with the smallest timeframe available."
Engine.Context(s::Strategy) = begin
    dr = DateRange(s.universe)
    Engine.Context(dr)
end

## Strategy interface
@doc "Called on each timestep iteration, possible multiple times.
Receives:
- `current_time`: the current timestamp to evaluate (the current candle would be `current_time - timeframe`).
- `orders`: orders that failed on the previous call.
- `trades`: the dict of active trades, the strategy can access, but should not modify."
process(::Strategy, current_time) = nothing
@doc "On which assets the strategy should be active."
assets(::Strategy) = AbstractAsset[]
@doc "On which exchange the strategy should be active."
exchange(::Strategy) = nothing
@doc "Called to construct the strategy, should return the strategy instance."
load(::Strategy) = nothing
@doc "How much lookback data the strategy needs. Used for backtesting."
warmup(s::Strategy) = s.timeframe.period

macro interface()
    quote
        import Engine.Strategies: process, assets, exchange, load, warmup
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
            # Core.eval(Main, :(using .$(nameof($src))))
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
    strat_exc = invokelatest(mod.exchange, mod.S).sym
    # The strategy can have a default exchange symbol
    if cfg.exchange == Symbol()
        cfg.exchange = strat_exc
    end
    @assert cfg.exchange == strat_exc "Config exchange $(cfg.exchange) doesn't match strategy exchange! $(strat_exc)"
    @assert nameof(mod.S) isa Symbol "Source $src does not define a strategy name."
    invokelatest(mod.load, mod.S, cfg)
end

function Base.display(strat::Strategy)
    out = IOBuffer()
    try
        write(out, "Strategy name: $(typeof(strat))\n")
        write(out, "Base Amount: $(strat.config.base_amount)\n")
        write(out, "Universe:\n")
        write(out, string(Collections.prettydf(strat.universe)))
        write(out, "\n")
        write(out, "Balances:\n")
        write(out, string(strat.holdings))
        write(out, "\n")
        write(out, "Orders:\n")
        write(out, string(strat.orders))
        Base.print(String(take!(out)))
    finally
        close(out)
    end
end

include("orders/orders.jl")

export Strategy, loadstrategy!, process, assets, exchange, load, warmup, @interface

end
