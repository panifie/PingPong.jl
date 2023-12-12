using Pkg: Pkg
using TOML
using JSON
using TimeTicks
using FunctionalCollections: PersistentHashMap
using .Lang: @lget!, Option, splitkws

# TODO: move config to own pkg
@doc """Finds the configuration file in the given path.

$(TYPEDSIGNATURES)

This function recursively searches for a file with the specified `name` starting from `cur_path`. It stops once the file is found or when it reaches the root directory.

"""
function find_config(cur_path=splitpath(pwd()); name="pingpong.toml", dir="user")
    length(cur_path) == 1 && return nothing
    this_file = joinpath(cur_path..., name)
    isfile(this_file) && return this_file
    this_file = joinpath(cur_path..., dir, name)
    isfile(this_file) && return this_file
    pop!(cur_path)
    return find_config(cur_path)
end

@doc """Returns the default directory path for the project.

$(TYPEDSIGNATURES)

This function returns the directory of the active project if it exists. Otherwise, it uses the `JULIA_PROJECT` from the environment variables. If neither exist, it defaults to the current directory.

"""
function default_dir()
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

user_dir() = begin
    cfg = find_config()
    if isnothing(cfg)
        default_dir()
    else
        dirname(cfg)
    end
end

@doc """Determines the config file path.

This function attempts to find the configuration file using `find_config()`. If it doesn't exist in the default directory, it falls back to the active project directory.

"""
function config_path()
    path = find_config()
    if isnothing(path)
        path = joinpath(default_dir(), "pingpong.toml")
        if !ispath(path)
            ppath = Base.active_project()
            @warn "Config file not found at $path, fallback to $ppath"
            path = ppath
        end
    end
    return path
end

@doc """Generates the path for the JSON keys file.

$(TYPEDSIGNATURES)

This function constructs a filename from the given `exc_name`, replacing any existing `.json` extension, and joins it with the user directory path.

"""
function keys_path(exc_name::AbstractString)
    cfg_dir = user_dir()
    file = lowercase((replace(exc_name, ".json" => "") * ".json"))
    joinpath(cfg_dir, file)
end

# TODO: should be unified into a single `secrets.toml` file
@doc """Retrieves the API keys for a specific exchange.

$(TYPEDSIGNATURES)

This function tries to open and parse a JSON file named after the exchange `name`, which should contain the API keys.

"""
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

@doc """ Strategy config.

$(FIELDS)

"""
@kwdef mutable struct Config{T<:Real}
    "File path that loaded this config."
    path::String = ""
    "Execution mode (`Sim`, `Paper`, `Live`)"
    mode::Option{ExecMode} = nothing
    "A symbol to instantiate an exchange (a raw ExchangeID symbol)"
    exchange::Symbol = Symbol()
    "Exchange sandbox mode flag"
    sandbox::Bool = true
    "The quote currency for the strategy cash."
    qc::Symbol = :USDT
    "Configures the margin mode of the strategy (`NoMargin`, `Isolated` or `Cross`)"
    margin::Option{MarginMode} = nothing
    "The default leverage that should be used when opening position with margin mode."
    leverage::T = 0.0
    "A minimum acceptable volume, e.g. for filtering markets."
    min_vol::T = 10e4
    "Starting cash, used when instantiating a strategy."
    initial_cash::T = 100.0
    "Default order size."
    min_size::T = 10.0
    "The default (shortest) timeframe of the candles."
    min_timeframe::TimeFrame = tf"1m"
    "Vector of sorted timeframes that the strategy uses (for loading data)."
    timeframes::Vector{<:TimeFrame} = [(timeframe(t) for t in ("1m", "15m", "1h", "1d"))...]
    "The default number of candles (OHLCV)."
    window::Period = Day(7)
    "Mapping of modules symbols name to (.jl) file paths"
    sources::Dict{Symbol,String} = Dict{Symbol,String}()
    "Generic metadata container."
    attrs::Dict{Any,Any} = Dict()
    "Raw toml that instantiated this config."
    toml = nothing
    "Initial config values (from toml)."
    const defaults::NamedTuple = (;)
end

function Config(args...; kwargs...)
    Config{DEFAULT_FLOAT_TYPE}(args...; kwargs...)
end

const config_fields = fieldnames(Config)

@doc """Creates a Config object from a profile and path.

$(TYPEDSIGNATURES)

This function creates a `Config` object using the provided `profile` and `path`. The `profile` can be a `Symbol`, `Module`, or `String` representing a specific configuration setup or a user/project profile. If `hasentry` is `true`, it also checks for an entry point.

"""
function Config(profile::Union{Symbol,Module,String}, path::String=config_path(); hasentry=true, kwargs...)
    config_kwargs, attrs_kwargs = splitkws(config_fields...; kwargs)
    cfg = Config(; config_kwargs...)
    name = _namestring(profile)
    config!(name; cfg, path, check=hasentry)
    cfg = Config(; defaults=_defaults(cfg))
    cfg[:config_overrides] = config_kwargs
    config!(name; cfg, path, check=hasentry)
    attrs = cfg.attrs
    for (k, v) in attrs_kwargs
        attrs[k] = v
    end
    cfg
end

Base.getindex(cfg::Config, k) = cfg.attrs[k]
Base.setindex!(cfg::Config, v, k) = setindex!(cfg.attrs, v, k)

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

@doc """Sets the path in cfg if the file exists.

$(TYPEDSIGNATURES)

This function sets the `path` field of the `cfg` object to the provided `path` if a file exists at that location.

"""
_path!(cfg, path) = begin
    if !isfile(path)
        throw("Config file not found at path $(config.path)")
    else
        cfg.path = path
    end
end

_namestring(profile::String) = profile
_namestring(profile::Symbol) = string(profile)
_namestring(profile::Module) = profile |> nameof |> string

@doc """Sets the TOML config in cfg if the file exists.

$(TYPEDSIGNATURES)

This function sets the `toml` field of the `cfg` object to the parsed contents of a TOML file with the provided `name`, if the file exists.

"""
function _toml!(cfg, name; check=true)
    cfg.toml = PersistentHashMap(
        [(
            (k, v) for (k, v) in TOML.parsefile(cfg.path) if
            k ∉ Set(("deps", "uuid", "extras", "compat"))
        )...,]
    )
    if check && name ∉ keys(cfg.toml) && name ∉ keys(get(cfg.toml, "sources", (;)))
        throw("Config section [$name] not found in the configuration read from $(cfg.path)")
    end
end
function _parse(k, v)
    if k == :mode || k == :margin
        mode = Symbol(uppercasefirst(string(v)))
        @eval Misc.$mode()
    else
        v
    end
end
@doc """Sets the options in cfg based on provided name.

$(TYPEDSIGNATURES)

This function iterates over the options defined in the `cfg` object's TOML and sets each option according to the values provided under the given `name`.

"""
function _options!(cfg, name)
    options = fieldnames(Config)
    attrs = cfg.attrs
    toml = cfg.toml
    opts = @something get(toml, name, nothing) if get(toml, "name", "") != name
        ()
    else
        get(toml, "strategy", ())
    end
    if isempty(opts) && name ∉ keys(get(toml, "sources", (;)))
        @warn "options: No options found for $name"
    end
    for (opt, val) in opts
        sym = Symbol(opt)
        if sym ∈ options
            setproperty!(cfg, sym, _parse(sym, val))
        else
            attrs[opt] = val
        end
    end
    sort!(cfg.timeframes)
end
@doc """Sets the sources in cfg based on provided name.

$(TYPEDSIGNATURES)

This function iterates over the sources defined in the `cfg` object's TOML and sets each source according to the values provided under the given `name`.

"""
_sources!(cfg, name) = begin
    for (k, v) in get(cfg.toml, "sources", ())
        cfg.sources[Symbol(k)] = v
    end
    for k in setdiff(keys(cfg.toml), Set([name, "sources"]))
        cfg.attrs[k] = cfg.toml[k]
    end
end

@doc """Parses the toml file and populates the config `cfg`.

$(TYPEDSIGNATURES)

This function updates the configuration object `cfg` by parsing the TOML file specified by `name` and `path`. If `check` is true, the function validates the config.

"""
function config!(name::String; cfg::Config=config, path::String=config_path(), check=true)
    _path!(cfg, path)
    _toml!(cfg, name; check)
    _options!(cfg, name)
    _sources!(cfg, name)
    for (k, v) in @lget! cfg.attrs :config_overrides Dict()
        setproperty!(cfg, k, v)
    end
    cfg
end

@doc """Resets the Config object to its default values.

$(TYPEDSIGNATURES)

This function iterates over the fields of the `Config` object `c` and resets each field to its default value. (stored in the `defaults` field)

"""
function reset!(c::Config)
    for k in fieldnames(Config)
        k == :defaults && continue
        if hasproperty(_config_defaults, k)
            def = getproperty(_config_defaults, k)
            setproperty!(c, k, _copyval(def))
        end
    end
end

@doc """Creates a (shallow) copy of the Config object.

$(TYPEDSIGNATURES)

This function returns a new `Config` object that is a copy of the given `Config` object `c`.

"""
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
