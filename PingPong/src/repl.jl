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
        modpath = joinpath(projpath, string(sym))
        try
            @eval Main using $sym: $sym as $bind
        catch e
            Base.showerror(stdout, e)
            prev = Pkg.project().path
            Pkg.activate(modpath)
            Pkg.instantiate()
            Pkg.activate(prev)
            @eval Main using $sym: $sym as $bind
        end
    end
    @info "`$sym` module bound to `$bind`"
end

plots!() = module!(:Plotting, :plo)
stats!() = module!(:Stats, :ss)
engine!() = module!(:Engine, :egn)
analysis!() = module!(:Analysis, :an)
stubs!() = module!(:Stubs, :stubs)
optplots!() =
    let prev = Pkg.project().path
        try
            Pkg.activate("Plotting")
            plots!()
        finally
            Pkg.activate(prev)
        end
    end

export plots!, optplots!, stats!, engine!, analysis!
