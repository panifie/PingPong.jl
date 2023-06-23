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

function _file(src, cfg)
    file = get(cfg.attrs, "include_file", nothing)
    if isnothing(file)
        file = get(cfg.sources, src, nothing)
        if isnothing(file)
            throw(ArgumentError("Section `$src` does not declare an `include_file` and \
                                section `sources` does not declare a `$src` key or \
                                its value is not a valid file."))
        end
    end
    file
end

function strategy!(src::Symbol, cfg::Config)
    file = _file(src, cfg)
    isproject = if splitext(file)[2] == ".toml"
        project_file = find_path(file, cfg)
        path = find_path(file, cfg)
        Misc.config!(src; cfg, path)
        file = _file(src, cfg)
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
                $isproject && Pkg.activate($project_file; io=Base.devnull)
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
    s_type = let s_type = mod.S{typeof(config.mode)}
        s_type = _concrete(s_type, typeof(config.margin))
        _concrete(s_type, typeof(config.qc))
    end
    strat_exc = exchange(s_type)
    # The strategy can have a default exchange symbol
    if cfg.exchange == Symbol()
        cfg.exchange = strat_exc
    end
    @assert cfg.exchange == strat_exc "Config exchange $(cfg.exchange) doesn't match strategy exchange! $(strat_exc)"
    @assert nameof(mod.S) isa Symbol "Source $src does not define a strategy name."
    invokelatest(mod.ping!, mod.S, cfg, LoadStrategy())
end
function strategy(src::Union{Symbol,Module,String}; config_args...)
    strategy!(src, Config(src; config_args...))
end

function _no_inv_contracts(exc::Exchange, uni)
    for ai in uni
        @assert something(get(exc.markets[ai.asset.raw], "linear", true), true) "Inverse contracts are not supported by SimMode."
    end
end
