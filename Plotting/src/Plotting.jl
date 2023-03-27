module Plotting
occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)

using Lang
using TimeTicks
using Makie: parent_scene, shift_project, update_tooltip_alignment!
using WGLMakie
using Stats

include("utils.jl")
include("ohlcv.jl")
include("trades.jl")

end # module Plotting
