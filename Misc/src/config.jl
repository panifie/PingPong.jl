using Pkg: Pkg
using TOML
using JSON
using TimeTicks
using FunctionalCollections: PersistentHashMap
# TODO: move config to own pkg

_config_dir() = begin
    ppath = Pkg.project().path
    joinpath(dirname(ppath), "cfg")
end

@doc "The config path (TOML), relative to the current project directory."
function config_path()
    cfg_dir = _config_dir()
    path = joinpath(cfg_dir, "backtest.toml")
    if !ispath(path)
        @warn "Config file not found at $path, creating anew."
        mkpath(cfg_dir)
        touch(path)
    end
    path
end

function keys_path(exc_name::AbstractString)
    cfg_dir = _config_dir()
    file = lowercase((replace(exc_name, ".json" => "") * ".json"))
    joinpath(cfg_dir, file)
end

function exchange_keys(name)::Dict{String,Any}
    try
        local cfg
        name = string(name)
        open(keys_path(name)) do f
            cfg = JSON.parse(f)
        end
        Dict(k => get(cfg, k, "") for k in ("apiKey", "secret", "password"))
    catch
        Dict()
    end
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
- `attrs`: Generic metadata container.
- `sources`: mapping of modules symbols name to (.jl) file paths
"""
@kwdef mutable struct Config15
    path::String = ""
    exchange::Symbol = Symbol()
    qc::Symbol = :USDT
    margin::Bool = false
    leverage::Symbol = :no # FIXME: Should be enum
    futures::Bool = false
    vol_min::Float64 = 10e4
    initial_cash::Float64 = 100.0
    base_amount::Float64 = 10.0
    base_timeframe::TimeFrame = tf"1m"
    timeframes::Vector{TimeFrame} = timeframe.(["1m", "15m", "1h", "1d"])
    window::Period = Day(7) # deprecated
    # - `slope/min/max`: Used in Analysios/slope.
    # - `ct`: Used in Analysis/corr.
    # slope_min::Float64= 0.
    # slope_max::Float64 = 90.
    # ct::Dict{Symbol, NamedTuple} = Dict()
    sources::Dict{Symbol,String} = Dict()
    attrs::Dict{Any,Any} = Dict()
    toml = nothing
end
Config = Config15

@doc "Global configuration instance."
const config = Config()
const SourcesDict = Dict{Symbol,String}

@doc "Sets a single config value."
config!(c::Config, k, v) = setproperty!(c, k, v)
globalconfig!(k, v) = config!(config, k, v)

_path!(cfg, path) = begin
    if !isfile(path)
        throw("Config file not found at path $(config.path)")
    else
        cfg.path = path
    end
end

_namestring(name) = begin
    name = convert(Symbol, name)
    string(name)
end

function _toml!(cfg, name)
    cfg.toml = PersistentHashMap(k => v for (k, v) in TOML.parsefile(cfg.path))
    if name ∉ keys(cfg.toml)
        throw("Config section [$name] not found in the configuration read from $(cfg.path)")
    end
end
function _options!(cfg, name)
    options = fieldnames(Config)
    for (opt, val) in cfg.toml[name]
        sym = Symbol(opt)
        if sym ∈ options
            config!(cfg, sym, val)
        else
            cfg.attrs[opt] = val
        end
    end
end
_sources!(cfg, name) = begin
    for (k, v) in cfg.toml["sources"]
        cfg.sources[Symbol(k)] = v
    end
    for k in setdiff(keys(cfg.toml), Set([name, "sources"]))
        cfg.attrs[k] = cfg.toml[k]
    end
end

@doc "Parses the toml file and populates the global `config`."
function loadconfig!(
    profile::T; path::String=config_path(), cfg::Config=config
) where {T<:Union{Symbol,String}}
    _path!(cfg, path)
    name = _namestring(profile)
    _toml!(cfg, name)
    _options!(cfg, name)
    _sources!(cfg, name)
    cfg
end

@doc "Reset global config to default values."
function resetconfig!(c=config)
    default = Config()
    for k in fieldnames(Config)
        config!(c, k, getproperty(default, k))
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

function __init__()
    resetconfig!()
end

export Config, loadconfig!, resetconfig!, exchange_keys
