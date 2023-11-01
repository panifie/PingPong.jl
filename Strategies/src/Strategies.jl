module Strategies

if get(ENV, "JULIA_NOPRECOMP", "") == "all"
    __init__() = begin
        include(joinpath(@__DIR__, "strategies.jl"))
    end
else
    occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)
    include("strategies.jl")
    if true # get(ENV, "JULIA_PRECOMPILE", "") == "yes"
        include("precompile.jl")
    else
        include("precompile_includer.jl")
    end
end

end # module Strategies
