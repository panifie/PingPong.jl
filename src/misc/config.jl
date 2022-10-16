using Base: @kwdef
using TOML
import Pkg

function config_path()
    ppath = Pkg.project().path
    joinpath(dirname(ppath), "cfg", "backtest.toml")
end

@kwdef mutable struct Config
    path = config_path()
    window::Int = 7
    timeframe::String = "1d"
    qc::String = "USDT"
    margin::Bool = false
    leverage::Symbol = :no
    futures::Bool = false
    vol_min::Float64 = 10e4
    slope_min::Float64= 0.
    slope_max::Float64 = 90.
    ct::Dict{Symbol, NamedTuple} = Dict()
    attrs::Dict{Any, Any} = Dict()
end

const config = Config()

function loadconfig(exc)
    if !isfile(config.path)
        throw("Config file not found at path $(config.path)")
    end
    exc = string(exc)
    cfg = TOML.parsefile(config.path)
    if exc ∉ keys(cfg)
        throw("Exchange config not found among possible exchanges $(keys(cfg))")
    end
    for (opt, val) in cfg[exc]
        setcfg!(Symbol(opt), val)
    end
end

function resetconfig!()
    default = Config()
    for k in fieldnames(Config)
        setcfg!(k, getproperty(default, k))
    end
end

macro margin!()
    :(config.margin = !config.margin)
end

macro lev!()
    :(config.leverage = !config.leverage)
end

setcfg!(k, v) = setproperty!(config, k, v)

resetconfig!()

export loadconfig
