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

function strategy!(src::Symbol, cfg::Config)
    file = get(cfg.attrs, "include_file", nothing)
    if isnothing(file)
        file = get(cfg.sources, src, nothing)
        if isnothing(file)
            throw(ArgumentError("Section `$src` does not declare an `include_file` and \
                                section `sources` does not declare a `$src` key or \
                                its value is not a valid file."))
        end
    end
    path = find_path(file, cfg)
    mod = if !isdefined(@__MODULE__, src)
        @eval begin
            if isdefined(Main, :Revise)
                @eval Main begin
                    Revise.includet($path)
                    using Main.$src
                    Main.$src
                end
            else
                include($path)
                using .$src
                $src
            end
        end
    else
        if isdefined(Main, :Revise)
            Core.eval(Main, src)
        else
            @eval $src
        end
    end
    strategy!(mod, cfg)
end
function strategy!(mod::Module, cfg::Config)
    strat_exc = exchange(mod.S{typeof(config.mode)})
    # The strategy can have a default exchange symbol
    if cfg.exchange == Symbol()
        cfg.exchange = strat_exc
    end
    @assert cfg.exchange == strat_exc "Config exchange $(cfg.exchange) doesn't match strategy exchange! $(strat_exc)"
    @assert nameof(mod.S) isa Symbol "Source $src does not define a strategy name."
    invokelatest(mod.ping!, mod.S, LoadStrategy(), cfg)
end
strategy(src::Union{Symbol,Module}; kwargs...) = strategy!(src, Config(src, kwargs...))
