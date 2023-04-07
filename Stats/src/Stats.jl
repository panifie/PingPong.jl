module Stats
occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)

using TimeTicks
using Processing: normalize!, resample
using OrderTypes
using Statistics

using Data.DataFrames
using Instances
using Engine.Strategies
using .Strategies: Strategies as st, Strategy

include("trades_resample.jl")
include("trades_balance.jl")

end # module Stats
