using Pkg: Pkg as Pkg

macro in_repl()
    quote
        @eval begin
            Misc.clearpypath!()
            an = Analysis
            using Plotting: plotone, @plotone
            using Misc: config, @margin!, @margin!!
        end
        exc = setexchange!(:kucoin)
    end
end

function analyze!()
    @eval using Analysis, Plotting
end

function user!()
    @eval include(joinpath(@__DIR__, "user.jl"))
    @eval using Misc: config
    @eval export results, exc, config
    @eval an = Analysis
    nothing
end

function module!(sym, bind)
    if !isdefined(Main, bind)
        projpath = dirname(dirname(pathof(PingPong)))
        modpath = joinpath(projpath, string(sym, ".jl"))
        try
            @eval Main using $sym: $sym as $bind
        catch e
            Base.showerror(stdout, e)
            prev = Pkg.project().path
            Pkg.activate(modpath)
            try
                @eval Main using $sym: $sym as $bind
            finally
                Pkg.activate(prev)
            end
        end
    end
    @info "`$sym` module bound to `$bind`"
end

# NOTE: required to register extensions hooks
function _activate_and_import(name, bind)
    proj_name = string(name)
    @assert isfile(joinpath(proj_name, "Project.toml"))
    prev = Base.active_project()
    Pkg.activate(proj_name, io=devnull)
    try
        module!(Symbol(name), Symbol(bind))
    finally
        Pkg.activate(prev, io=devnull)
    end
end

plots!() = _activate_and_import(:Plotting, :plo)
stats!() = module!(:Stats, :ss)
engine!() = module!(:Engine, :egn)
analysis!() = module!(:Analysis, :an)
stubs!() = module!(:Stubs, :stubs)
optim!() = _activate_and_import(:Optimization, :opt)
interactive!() = _activate_and_import(:PingPongInteractive, :ppi)

export plots!, optim!, stats!, engine!, analysis!, interactive!
