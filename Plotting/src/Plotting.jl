module Plotting
occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)

using Lang
using TimeTicks
using Misc
using Makie
using Makie: parent_scene, shift_project, update_tooltip_alignment!, Figure
using Stats

include("utils.jl")
include("ohlcv.jl")
include("trades.jl")
include("inds.jl")

end # module Plotting
