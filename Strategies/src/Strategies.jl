module Strategies
occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)

include("strategies.jl")

end # module Strategies
