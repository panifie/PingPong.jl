using .Data.Cache: save_cache, load_cache
using .Misc: user_dir, config_path
using .Misc.Lang: @debug_backtrace

@doc """ Raises an error when a strategy is not found at a given path.  """
macro notfound(path)
    quote
        error("Strategy not found at $($(esc(path)))")
    end
end

@doc """ Finds the path of a given file.

$(TYPEDSIGNATURES)

The `find_path` function checks various locations to find the path of a given file.
It checks the current working directory, user directory, configuration directory, and project directory.
If the file is not found, it raises an error.
"""
function find_path(file, cfg)
    if !ispath(file)
        if isabspath(file)
            @notfound file
        else
            from_pwd = joinpath(pwd(), file)
            ispath(from_pwd) && return from_pwd
            from_user = joinpath(user_dir(), file)
            ispath(from_user) && return from_user
            from_cfg = joinpath(dirname(cfg.path), file)
            ispath(from_cfg) && return from_cfg
            from_proj = joinpath(dirname(Pkg.project().path), file)
            ispath(from_proj) && return from_proj
            @notfound file
        end
    end
    realpath(file)
end

_default_projectless(src) = joinpath(user_dir(), "strategies", string(src, ".jl"))
@doc """ Retrieves the source file for a strategy without a project.

The `_include_projectless` function retrieves the source file for a strategy that does not have a project.
It checks the `sources` attribute of the strategy's configuration.
"""
_include_projectless(src, attrs) =
    if !isnothing(attrs)
        let sources = get(attrs, "sources", nothing)
            if !isnothing(sources)
                get(sources, string(src), nothing)
            end
        end
    end
_include_project(attrs) = get(attrs, "include_file", nothing)

@doc """ Determines the file path for a strategy source.

$(TYPEDSIGNATURES)

This function determines the file path for a strategy source based on whether it is a project or not.
If it is a project, it constructs the file path relative to the configuration path.
If it is not a project, it retrieves the source file from the strategy's configuration or defaults to a predefined path.
In case the file path is not found, it throws an `ArgumentError` with a detailed message.
"""
function _file(src, cfg, is_project)
    file = if is_project
        file = joinpath(dirname(realpath(cfg.path)), "src", string(src, ".jl"))
        if ispath(file)
            file
        else
        end
    else
        @something _include_project(cfg.attrs) _include_projectless(src, cfg.toml) _default_projectless(
            src
        )
    end
    if isnothing(file)
        file = get(cfg.sources, src, nothing)
        if isnothing(file)
            msg = if is_project
                "Strategy include file not found for project $src, \
                declare `include_file` manually in strategy config \
                or ensure `src/$src.jl is present. cfg: $(cfg.path) file: ($file)"
            else
                "Section `$src` does not declare an `include_file` and \
                section `sources` does not declare a `$src` key or \
                its value is not a valid file. cfg: $(cfg.path) file: $(file)"
            end
            throw(ArgumentError(msg))
        end
    end
    file
end

@doc """ Determines the margin mode of a module.

$(TYPEDSIGNATURES)

This function attempts to determine the margin mode of a given module.
It first tries to access the `S` property of the module to get the margin mode.
If this fails, it then tries to access the `SC` property of the module.
"""
function _defined_marginmode(mod)
    try
        marginmode(mod.S)
    catch
        marginmode(mod.SC)
    end
end

@doc """ Performs checks on a loaded strategy.

$(TYPEDSIGNATURES)

This function performs checks on a loaded strategy.
It asserts that the margin mode and execution mode of the strategy match the configuration.
It also sets the `verbose` property of the strategy to `false`.
"""
_strat_load_checks(s::Strategy, config::Config) = begin
    @assert marginmode(s) == config.margin
    @assert execmode(s) == config.mode
    @assert account(s) == config.account
    s[:verbose] = false
    s
end

@doc """ Loads a strategy with default settings.

$(TYPEDSIGNATURES)

This function loads a strategy with default settings.
It invokes the `ping!` function of the module with the strategy type and `StrategyMarkets()`.
It then creates a new `Strategy` instance with the module, assets, and configuration.
The `sandbox` property is set based on the mode of the configuration.
Finally, it performs checks on the loaded strategy.
"""
function default_load(mod::Module, t::Type, config::Config)
    assets = invokelatest(mod.ping!, t, StrategyMarkets())
    if config.mode == Paper()
        config.sandbox = true
    end
    s = Strategy(mod, assets; config)
    _strat_load_checks(s, config)
end

@doc """ Loads a strategy without default settings.

$(TYPEDSIGNATURES)

This function loads a strategy without default settings.
It invokes the `ping!` function of the module with the strategy type and `StrategyMarkets()`.
It then creates a new `Strategy` instance with the module, assets, and configuration.
The `sandbox` property is set based on the mode of the configuration.
Finally, it performs checks on the loaded strategy.
"""
function bare_load(mod::Module, t::Type, config::Config)
    syms = invokelatest(mod.ping!, t, StrategyMarkets())
    exc = Exchanges.getexchange!(config.exchange; sandbox=true, config.account)
    uni = AssetCollection(syms; load_data=false, timeframe=mod.TF, exc, config.margin)
    s = Strategy(mod, config.mode, config.margin, mod.TF, exc, uni; config)
    _strat_load_checks(s, config)
end

@doc """ Loads a strategy from a symbol source.

$(TYPEDSIGNATURES)

This function loads a strategy from a given symbol source.
It first determines the file path for the strategy source and checks if it is a project.
If it is a project, it activates and instantiates the project.
The function then includes the source file and uses it.
If the source file is not defined in the parent module, it is evaluated and tracked for changes.
Finally, the function returns the loaded strategy.
"""
function strategy!(src::Symbol, cfg::Config)
    file = _file(src, cfg, false)
    isproject = if splitext(file)[2] == ".toml"
        project_file = find_path(file, cfg)
        path = find_path(file, cfg)
        name = string(src)
        Misc.config!(name; cfg, path, check=false)
        file = _file(src, cfg, true)
        true
    else
        project_file = nothing
        false
    end
    prev_proj = Base.active_project()
    path = find_path(file, cfg)
    parent = get(cfg.attrs, :parent_module, Main)
    @assert parent isa Module "loading: $parent is not symbol (module)"
    mod = if !isdefined(parent, src)
        @eval parent begin
            try
                let
                    using Pkg: Pkg
                    if $isproject
                        @debug "loading: " strat = $project_file
                        Pkg.activate($project_file; io=Base.devnull)
                        try
                            Pkg.instantiate(; io=Base.devnull)
                        catch e
                            @error "loading: failed instantiation" exception = e
                        end
                        using $src
                    else
                        include($path)
                        using .$src
                    end
                    if isinteractive() && isdefined(Main, :Revise)
                        Main.Revise.track($src, $path)
                    end
                    $src
                end
            finally
                if $isproject
                    Pkg.activate($prev_proj; io=Base.devnull)
                end
            end
        end
    else
        @eval parent $src
    end
    strategy!(mod, cfg)
end
_concrete(type, param) = isconcretetype(type) ? type : type{param}
@doc """ Determines the strategy type of a module.

$(TYPEDSIGNATURES)

This function determines the strategy type of a given module.
It first tries to access the `S` property of the module to get the strategy type.
If this fails, it then tries to access the `SC` property of the module.
The function also checks if the exchange is specified in the strategy or in the configuration.
"""
function _strategy_type(mod, cfg)
    s_type =
        if isdefined(mod, :S) &&
            mod.S isa Type{<:Strategy} &&
            exchangeid(mod.S) == exchangeid(cfg.exchange)
            mod.S
        else
            if cfg.exchange == Symbol()
                if isdefined(mod, :EXCID) && mod.EXCID != Symbol()
                    cfg.exchange = mod.EXCID
                elseif isdefined(mod, :S)
                    cfg.exchange = exchangeid(mod.S)
                else
                    error(
                        "loading: exchange not specified (neither in strategy nor in config)",
                    )
                end
            end
            try
                if isdefined(mod, :EXCID) && mod.EXCID != cfg.exchange
                    @warn "loading: overriding default exchange with config" mod.EXCID cfg.exchange
                end
                mod.SC{ExchangeID{cfg.exchange}}
            catch
                error(
                    "loading: strategy main type `S` or `SC` not defined in strategy module.",
                )
            end
        end
    mode_type = s_type{typeof(cfg.mode)}
    margin_type = _concrete(mode_type, typeof(cfg.margin))
    _concrete(margin_type, typeof(cfg.qc))
end
@doc """ Loads a strategy from a module.

$(TYPEDSIGNATURES)

This function loads a strategy from a given module.
It first checks and sets the mode and margin of the configuration if they are not set.
It then determines the strategy type of the module and checks if the exchange is specified in the strategy or in the configuration.
Finally, it tries to load the strategy with default settings, if it fails, it loads the strategy without default settings.
"""
function strategy!(mod::Module, cfg::Config)
    if isnothing(cfg.mode)
        cfg.mode = Sim()
    end
    def_mm = _defined_marginmode(mod)
    if isnothing(cfg.margin)
        cfg.margin = def_mm
    elseif def_mm != cfg.margin
        @warn "Mismatching margin mode" config = cfg.margin strategy = def_mm
    end
    s_type = _strategy_type(mod, cfg)
    strat_exc = Symbol(exchangeid(s_type))
    # The strategy can have a default exchange symbol
    if cfg.exchange == Symbol()
        cfg.exchange = strat_exc
        if strat_exc == Symbol()
            @warn "Strategy exchange unset"
        end
    end
    if cfg.min_timeframe == tf"0s" # any zero tf should match
        cfg.min_timeframe = tf"1m" # default to 1 minute timeframe
        tfs = cfg.timeframes
        sort!(tfs)
        idx = searchsortedfirst(tfs, tf"1m")
        if length(tfs) < idx || tfs[idx] != tf"1m"
            insert!(tfs, idx, tf"1m")
        end
    end
    @assert nameof(s_type) isa Symbol "Source $src does not define a strategy name."
    s = @something invokelatest(mod.ping!, s_type, cfg, LoadStrategy()) try
        default_load(mod, s_type, cfg)
    catch
        @debug_backtrace
        nothing
    end bare_load(mod, s_type, cfg)
    # ensure strategy is stopped on process termination
    atexit(() -> stop!(s))
    return s
end

@doc """ Returns the path to the strategy cache.

$(TYPEDSIGNATURES)

This function returns the path to the strategy cache.
It checks if the path exists and creates it if it doesn't.
"""
function strategy_cache_path()
    cache_path = user_dir()
    @assert ispath(cache_path) "Can't load strategy state, no directory at $cache_path"
    cache_path = joinpath(cache_path, "cache")
    mkpath(cache_path)
    cache_path
end

@doc """ Determines the configuration for a strategy.

$(TYPEDSIGNATURES)

This function determines the configuration for a strategy based on the source and path.
If the strategy is to be loaded, it attempts to load the strategy cache.
If the cache does not exist or is not a valid configuration, it creates a new configuration.
"""
function _strategy_config(src, path; load, config_args...)
    if load
        cache_path = strategy_cache_path()
        cfg = load_cache(string(src); raise=false, cache_path)
        if !(cfg isa Config)
            @warn "Strategy state ($src) not found at $cache_path"
            Config(src, path; config_args...)
        else
            cfg
        end
    else
        Config(src, path; config_args...)
    end
end

@doc """ Loads a strategy from a source, module, or string.

$(TYPEDSIGNATURES)

This function loads a strategy from a given source, module, or string.
It first determines the configuration for the strategy based on the source and path.
If the strategy is to be loaded, it attempts to load the strategy cache.
Finally, it returns the loaded strategy.
"""
function strategy(
    src::Union{Symbol,Module,String}, path::String=config_path(); load=false, config_args...
)
    cfg = _strategy_config(src, path; load, config_args...)
    strategy(src, cfg; save=load)
end

function strategy(src::Union{Symbol,Module,String}, cfg::Config; save=false)
    s = strategy!(src, cfg)
    save && save_strategy(s)
    s
end

@doc """ Returns the default strategy (`BareStrat`). """
strategy() = strategy(:BareStrat; parent_module=Strategies)

@doc """ Saves the state of a strategy.

$(TYPEDSIGNATURES)

This function saves the state of a given strategy.
It determines the cache path and saves the strategy state to this path.
"""
function save_strategy(s)
    cache_path = @lget! attrs(s) :config_cache_path strategy_cache_path()
    save_cache(string(nameof(s)); raise=false, cache_path)
end

@doc """ Checks for inverse contracts in an exchange.

$(TYPEDSIGNATURES)

This function checks for the presence of inverse contracts in a given exchange.
If any inverse contracts are found, it asserts an error.
"""
function _no_inv_contracts(exc::Exchange, uni)
    for ai in uni
        sym = raw(ai)
        @assert something(get(exc.markets[sym], "linear", true), true) "Inverse contracts are not supported by SimMode. $(sym)"
    end
end
