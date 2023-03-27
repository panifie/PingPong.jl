module Engine
occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)

include("engine.jl")
include("precompile_includer.jl")
end # module PingPong
