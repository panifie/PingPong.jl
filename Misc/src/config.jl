using Pkg: Pkg
using TOML
using JSON
using TimeTicks
using FunctionalCollections: PersistentHashMap
# TODO: move config to own pkg

_config_dir() = begin
    ppath = Base.active_project()
    ppath = if isempty(ppath)
        get(ENV, "JULIA_PROJECT", "")
    else
        dirname(ppath)
    end
    if isempty(ppath)
        ppath = "."
    else
        ppath = ppath * "/../"
    end
    joinpath(dirname(ppath), "user")
end

@doc "The config path (TOML), relative to the current project directory."
function config_path()
    cfg_dir = _config_dir()
    path = joinpath(cfg_dir, "config.toml")
    if !ispath(path)
        ppath = Base.active_project()
        @warn "Config file not found at $path, fallback to $ppath"
        path = ppath
    end
    path
end

function keys_path(exc_name::AbstractString)
    cfg_dir = _config_dir()
    file = lowercase((replace(exc_name, ".json" => "") * ".json"))
    joinpath(cfg_dir, file)
end

# TODO: should be unified into a single `secrets.toml` file
function exchange_keys(name; sandbox)::Dict{String,Any}
    try
        local cfg
        name = sandbox ? "$(name)_sandbox" : string(name)
        open(keys_path(name)) do f
            cfg = JSON.parse(f)
        end
        Dict(k => get(cfg, k, "") for k in ("apiKey", "secret", "password"))
    catch
        Dict()
    end
end

@doc """The config main structure:
- `path`: File path that loaded this config.
- `mode`: Execution mode (`Sim`, `Paper`, `Live`)
- `exchange`: A symbol to instantiate an exchange (a raw ExchangeID symbol)
- `qc`: The quote currency for the strategy cash.
- `margin`: configures the margin mode of the strategy (`NoMargin`, `Isolated` or `Cross`)
- `leverage`: The default leverage that should be used when opening position with margin mode.
- `min_vol`: A minimum acceptable volume, e.g. for filtering markets.
- `initial_cash`: Starting cash, used when instantiating a strategy.
- `min_size`: Default order size.
- `min_timeframe`: The default (shortest) timeframe of the candles.
- `timeframes`: Vector of sorted timeframes that the strategy uses (for loading data).
- `window`: (deprecated) The default number of candles (OHLCV).
- `attrs`: Generic metadata container.
- `sources`: mapping of modules symbols name to (.jl) file paths
"""
@kwdef mutable struct Config{T<:Real}
    path::String = ""
    mode::ExecMode = Sim()
    exchange::Symbol = Symbol()
    margin::MarginMode = NoMargin()
    leverage::T = 0.0
    qc::Symbol = :USDT
    initial_cash::T = 100.0
    min_vol::T = 10e4
    min_size::T = 10.0
    min_timeframe::TimeFrame = tf"1m"
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
    const defaults::NamedTuple = (;)
end

function Config(args...; kwargs...)
    Config{DEFAULT_FLOAT_TYPE}(args...; kwargs...)
end

function Config(profile::Union{Symbol,String}, path::String=config_path())
    cfg = Config()
    config!(profile; cfg, path)
    cfg = Config(; defaults=_defaults(cfg))
    config!(profile; cfg, path)
end

_copyval(v) =
    if typeof(v) <: Union{AbstractDict,AbstractVector}
        copy(v)
    else
        v
    end

function _defaults(cfg)
    NamedTuple(
        f => getfield(cfg, f) |> _copyval for f in fieldnames(Config) if f != :defaults
    )
end

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
    cfg.toml = PersistentHashMap(
        collect(
            (k, v) for (k, v) in TOML.parsefile(cfg.path) if
            k ∉ Set(("deps", "name", "uuid", "extras", "compat"))
        ),
    )
    if name ∉ keys(cfg.toml)
        throw("Config section [$name] not found in the configuration read from $(cfg.path)")
    end
end
function _parse(k, v)
    if k == :mode || k == :margin
        mode = Symbol(titlecase(string(v)))
        @eval Misc.$mode()
    else
        v
    end
end
function _options!(cfg, name)
    options = fieldnames(Config)
    attrs = cfg.attrs
    for (opt, val) in cfg.toml[name]
        sym = Symbol(opt)
        if sym ∈ options
            setproperty!(cfg, sym, _parse(sym, val))
        else
            attrs[opt] = val
        end
    end
    sort!(cfg.timeframes)
end
_sources!(cfg, name) = begin
    for (k, v) in get(cfg.toml, "sources", ())
        cfg.sources[Symbol(k)] = v
    end
    for k in setdiff(keys(cfg.toml), Set([name, "sources"]))
        cfg.attrs[k] = cfg.toml[k]
    end
end

@doc "Parses the toml file and populates the config `cfg` (defaults to global config)."
function config!(
    profile::Union{Symbol,String}; cfg::Config=config, path::String=config_path()
)
    _path!(cfg, path)
    name = _namestring(profile)
    _toml!(cfg, name)
    _options!(cfg, name)
    _sources!(cfg, name)
    cfg
end

@doc "Reset config to default values."
function reset!(c::Config)
    for k in fieldnames(Config)
        k == :defaults && continue
        if hasproperty(_config_defaults, k)
            def = getproperty(_config_defaults, k)
            setproperty!(c, k, _copyval(def))
        end
    end
end

@doc "Shallow copies the config, and top level containers fields `timeframes` and `attrs`."
Base.copy(c::Config) = begin
    c = Config((f = getfield(c, f) for f in fieldnames(Config))...)
    c.timeframes = copy(c.timeframes)
    c.attrs = copy(c.attrs)
    c
end

@doc "Toggle config margin flag."
macro margin!()
    quote
        config.margin = let mode = config.margin
            if mode == NoMargin()
                Isolated()
            elseif mode == Isolated()
                Cross()
            else
                NoMargin()
            end
        end
    end
end

@doc "Toggle config leverage flag"
macro lev!()
    quote
        config.leverage = let leverage = config.leverage
            if 0 <= leverage < 10.0
                10.0
            elseif 10 <= leverage < 100.0
                100.0
            else
                0.0
            end
        end
    end
end

export Config, config, config!, reset!, exchange_keys
