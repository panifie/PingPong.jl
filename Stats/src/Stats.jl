module Stats
occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)
using Statistics

using TimeTicks
using Data.DataFrames
using Processing: normalize!, resample

using OrderTypes
using Instances
using Strategies: Strategies as st, Strategy

include("trades_resample.jl")
include("trades_balance.jl")

end # module Stats
