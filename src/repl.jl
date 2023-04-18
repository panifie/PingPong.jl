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

# macro module!(sym, bind)
#     quote
#         if !isdefined(Main, $(QuoteNode(bind)))
#             projpath = dirname(dirname(pathof(PingPong)))
#             @info "Adding $($(string(sym))) project into `LOAD_PATH`"
#             modpath = joinpath(projpath, string($(QuoteNode(sym))))
#             modpath ∉ LOAD_PATH && push!(LOAD_PATH, modpath)
#             try
#                 @eval Main using $sym: $sym as $bind
#             catch
#                 prev = Pkg.project().path
#                 Pkg.activate(modpath)
#                 Pkg.instantiate()
#                 Pkg.activate(prev)
#                 @eval Main using $sym: $sym as $bind
#             end
#         end
#     end
# end

function module!(sym, bind)
    if !isdefined(Main, bind)
        projpath = dirname(dirname(pathof(PingPong)))
        @info "Adding $(string(sym)) project into `LOAD_PATH`"
        modpath = joinpath(projpath, string(sym))
        modpath ∉ LOAD_PATH && push!(LOAD_PATH, modpath)
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

export plots!, stats!, engine!, analysis!
