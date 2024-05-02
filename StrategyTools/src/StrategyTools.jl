module StrategyTools

let entry_path = joinpath(@__DIR__, "module.jl")
    if get(ENV, "JULIA_NOPRECOMP", "") == "all"
        @eval __init__() = begin
            @eval include($entry_path)
        end
    else
        occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) &&
            __precompile__(false)
        include(entry_path)
        if occursin(string(@__MODULE__), get(ENV, "JULIA_PRECOMP", ""))
            include("precompile.jl")
        end
    end
end

end # module LiveMode
