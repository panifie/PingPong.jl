using Makie
using Makie: parent_scene, shift_project, update_tooltip_alignment!, Figure
using Metrics
using Metrics: ect
using .ect.Misc
using .Misc.TimeTicks
using .Misc.Lang

include("utils.jl")
include("ohlcv.jl")
include("trades.jl")
include("inds.jl")

plot_results(args...; kwargs...) = error("not implemented")
