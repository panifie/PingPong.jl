module Plotting

using Makie: parent_scene, shift_project, update_tooltip_alignment!
using WGLMakie

include("ohlcv.jl")
include("trades.jl")

end # module Plotting
