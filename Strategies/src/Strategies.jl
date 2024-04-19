module Strategies

if get(ENV, "JULIA_NOPRECOMP", "") == "all"
    __init__() = begin
        entrypath = joinpath(@__DIR__, "module.jl")
        include(entrypath)
        if isdefined(Main, :Revise)
            Main.Revise.track(Strategies, @__FILE__)
        end
    end
else
    if occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", ""))
        __precompile__(false)
    end
    include("module.jl")
    include("precompile.jl")
end

end # module Strategies
