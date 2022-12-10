using Base: @kwdef
using TOML
import Pkg

@doc "The config path (TOML), relative to the current project directory."
function config_path()
    ppath = Pkg.project().path
    joinpath(dirname(ppath), "cfg", "backtest.toml")
end

@doc """The config main structure:
- `window`: The default number of candles (OHLCV).
- `timeframe`: The default timeframe of the candles.
- `qc`: The default quote currency.
- `margin`: If margin is enabled, only margin pairs are considered.
- `leverage`:
    - `:yes` : leveraged pairs will not be filtered.
    - `:only` : ONLY leveraged will not be filtered.
    - `:from` : Selects non leveraged pairs, that also have a leveraged siblings.
- `futures`: Selects the futures version of an Exchange.
- `slope/min/max`: Used in Analysios/slope.
- `ct`: Used in Analysis/corr.
- `attrs`: Generic metadata container.
"""
@kwdef mutable struct Config
    path = config_path()
    window::Int = 7
    timeframe::String = "1d"
    qc::String = "USDT"
    margin::Bool = false
    leverage::Symbol = :no # FIXME: Should be enum
    futures::Bool = false
    vol_min::Float64 = 10e4
    slope_min::Float64= 0.
    slope_max::Float64 = 90.
    ct::Dict{Symbol, NamedTuple} = Dict()
    attrs::Dict{Any, Any} = Dict()
end

@doc "Global configuration instance."
const config = Config()

@doc "Parses the toml file and populates the global `config`."
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

@doc "Reset global config to default values."
function resetconfig!()
    default = Config()
    for k in fieldnames(Config)
        setcfg!(k, getproperty(default, k))
    end
end

@doc "Toggle config margin flag."
macro margin!()
    :(config.margin = !config.margin)
end

@doc "Toggle config leverage flag"
macro lev!()
    :(config.leverage = !config.leverage)
end

@doc "Sets a single config value."
setcfg!(k, v) = setproperty!(config, k, v)

resetconfig!()

export loadconfig
