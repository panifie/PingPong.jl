module Stats
occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)

using Processing: normalize!
include("trades_resample.jl")

end # module Stats
