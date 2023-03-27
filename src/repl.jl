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

function plots!()
    if !isdefined(Main, :plo)
        projpath = dirname(dirname(pathof(PingPong)))
        @info "Adding Plotting project into `LOAD_PATH`"
        plotspath = joinpath(projpath, "Plotting")
        plotspath ∉ LOAD_PATH && push!(LOAD_PATH, plotspath)
        try
            @eval Main using Plotting: Plotting as plo
        catch
            prev = Pkg.project().path
            Pkg.activate(plotspath)
            Pkg.instantiate()
            Pkg.activate(prev)
            @eval Main using Plotting: Plotting as plo
        end
    end
end
