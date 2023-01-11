module Strategies
using Pkg: Pkg
using Dates: DateTime
using ExchangeTypes
using Misc: Config, config, Iterable, Candle, TimeFrame
using Pairs: Asset
using ..Collections
using ..Trades
using ..Instances
using ..Orders

@doc """The strategy is the core type of the framework.
- universe: All the assets that the strategy knows about
- portfolio: assets with open orders or >0 balance.
- orders: all active orders
- base_amount: The minimum size of an order
"""
struct Strategy15{M,N}
    universe::AssetCollection
    portfolio::Dict{ExchangeID,Dict{Asset,Ref{AssetInstance}}}
    orders::Dict{ExchangeID,Dict{Asset,Ref{AssetInstance}}}
    timeframes::NTuple{N,TimeFrame}
    base_amount::Float64
    config::Config
    Strategy15(src::Symbol, assets::Union{Dict,Iterable{String}}, config::Config) = begin
        uni = AssetCollection(assets)
        n_timeframes = length(config.timeframes)
        new{src,n_timeframes}(uni, Dict(), Dict(), (config.timeframes...,), 10.0, config)
    end
end
Strategy = Strategy15

@doc "Clears all orders history from strategy."
clearorders!(strat::Strategy) = begin
    empty!(strat.orders)
    for inst in strat.universe.data.instance
        empty!(inst.orders)
    end
end
@doc "Reloads ohlcv data for assets already present in the strategy universe."
reload!(strat::Strategy) = begin
    for inst in strat.universe.data.instance
        empty!(inst.data)
        load!(inst; reset=true)
    end
end

process(::Strategy, date::DateTime, orders::Vector{LiveOrder}) = Order((Buy, 0))
assets(::Strategy, e::ExchangeID=nothing) = Asset[]
get_pairs(::Strategy) = String[]

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

function loadstrategy!(src::Symbol, cfg=config)
    file = get(cfg.sources, src, nothing)
    if isnothing(file)
        throw(KeyError("Symbol $src not found in config $(config.path)."))
    end
    path = find_path(file, cfg)
    mod = @eval begin
        include($path)
        using .$src: $src
        if isdefined(Main, :Revise)
            Core.eval(Main, :(Revise.track($$src)))
        end
        $src
    end
    @assert isdefined(mod, :name) && mod.name isa Symbol "Source $src does not define a strategy name."
    pairs = Base.invokelatest(mod.get_pairs, Strategy{mod.name})
    Strategy(mod.name, pairs, cfg)
end

Base.display(strat::Strategy) = begin
    out = IOBuffer()
    try
        write(out, "Strategy name: $(typeof(strat))\n")
        write(out, "Base Amount: $(strat.base_amount)\n")
        write(out, "Universe:\n")
        write(out, string(Collections.prettydf(strat.universe)))
        write(out, "\n")
        write(out, "Portfolio:\n")
        write(out, string(strat.portfolio))
        write(out, "\n")
        write(out, "Orders:\n")
        write(out, string(strat.orders))
        Base.print(String(take!(out)))
    finally
        close(out)
    end
end

export Strategy, loadstrategy!, process, assets, get_pairs

end
