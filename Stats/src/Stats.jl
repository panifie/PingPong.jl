module Stats
occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)

using TimeTicks
using Processing: normalize!, resample
include("trades_resample.jl")
include("trades_balance.jl")

end # module Stats
