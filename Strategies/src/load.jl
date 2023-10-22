using Data.Cache: save_cache, load_cache
using Misc: _config_dir

macro notfound(path)
    quote
        error("Strategy not found at $($(esc(path)))")
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

function _file(src, cfg, is_project)
    file = if is_project
        file = joinpath(dirname(realpath(cfg.path)), "src", string(src, ".jl"))
        if ispath(file)
            file
        else
        end
    else
        get(attrs(cfg), "include_file", nothing)
    end
    if isnothing(file)
        file = get(cfg.sources, src, nothing)
        if isnothing(file)
            msg = if is_project
                "Strategy include file not found for project $src, \
                declare `include_file` manually in strategy config \
                or ensure `src/$src.jl is present."
            else
                "Section `$src` does not declare an `include_file` and \
                section `sources` does not declare a `$src` key or \
                its value is not a valid file."
            end
            throw(ArgumentError(msg))
        end
    end
    file
end

function default_load(mod, t, config)
    assets = invokelatest(mod.ping!, t, StrategyMarkets())
    config.margin = Isolated()
    sandbox = config.mode == Paper() ? false : config.sandbox
    s = Strategy(mod, assets; config, sandbox)
    @assert marginmode(s) == config.margin
    @assert execmode(s) == config.mode
    s[:verbose] = false
    s
end

function strategy!(src::Symbol, cfg::Config)
    file = _file(src, cfg, false)
    isproject = if splitext(file)[2] == ".toml"
        project_file = find_path(file, cfg)
        path = find_path(file, cfg)
        Misc.config!(src; cfg, path, check=false)
        file = _file(src, cfg, true)
        true
    else
        project_file = nothing
        false
    end
    prev_proj = Base.active_project()
    path = find_path(file, cfg)
    mod = if !isdefined(Main, src)
        @eval Main begin
            try
                using Pkg: Pkg
                $isproject && begin
                    Pkg.activate($project_file; io=Base.devnull)
                    Pkg.instantiate(; io=Base.devnull)
                end
                if isdefined(Main, :Revise)
                    Main.Revise.includet($path)
                else
                    include($path)
                end
                using Main.$src
                Main.$src
            finally
                $isproject && Pkg.activate($prev_proj; io=Base.devnull)
            end
        end
    else
        @eval Main $src
    end
    strategy!(mod, cfg)
end
_concrete(type, param) = isconcretetype(type) ? type : type{param}
function strategy!(mod::Module, cfg::Config)
    s_type =
        let s_type = try
                mod.S
            catch
                if cfg.exchange == Symbol()
                    if hasproperty(mod, :EXCID) && mod.EXCID != Symbol()
                        cfg.exchange = mod.EXCID
                    else
                        error(
                            "loading: exchange not specified (neither in strategy nor in config)",
                        )
                    end
                end
                try
                    if hasproperty(mod, :EXCID) && mod.EXCID != cfg.exchange
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
    strat_exc = nameof(exchangeid(s_type))
    # The strategy can have a default exchange symbol
    if cfg.exchange == Symbol()
        cfg.exchange = strat_exc
    end
    if attr(cfg, :exchange_override, false)
        @assert cfg.exchange == strat_exc "Config exchange $(cfg.exchange) doesn't match strategy exchange! $(strat_exc)"
    end
    @assert nameof(s_type) isa Symbol "Source $src does not define a strategy name."
    @something invokelatest(mod.ping!, s_type, cfg, LoadStrategy()) default_load(
        mod, s_type, cfg
    )
end

function strategy_cache_path()
    cache_path = _config_dir()
    @assert ispath(cache_path) "Can't load strategy state, no directory at $cache_path"
    cache_path = joinpath(cache_path, "cache")
    mkpath(cache_path)
    cache_path
end

function strategy(src::Union{Symbol,Module,String}; load=false, config_args...)
    cfg = if load
        cache_path = strategy_cache_path()
        cfg = load_cache(string(src); raise=false, cache_path)
        if !(cfg isa Config)
            @warn "Strategy state ($src) not found at $cache_path"
            Config(src; config_args...)
        else
            cfg
        end
    else
        Config(src; config_args...)
    end
    s = strategy!(src, cfg)
    load && save_strategy(s)
    s
end

function save_strategy(s)
    cache_path = @lget! attrs(s) :config_cache_path strategy_cache_path()
    save_cache(string(nameof(s)); raise=false, cache_path)
end

function _no_inv_contracts(exc::Exchange, uni)
    for ai in uni
        @assert something(get(exc.markets[ai.asset.raw], "linear", true), true) "Inverse contracts are not supported by SimMode."
    end
end
