module Stubs

if get(ENV, "JULIA_NOPRECOMP", "") == "all"
    __init__() = begin
        include(joinpath(@__DIR__, "stubs.jl"))
    end
else
    occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)
    include("stubs.jl")
end

end
