using Makie
using Makie: parent_scene, shift_project, update_tooltip_alignment!, Figure
using Stats
using Stats: egn
using .egn.Misc
using .egn.TimeTicks
using .egn.Lang

include("utils.jl")
include("ohlcv.jl")
include("trades.jl")
include("inds.jl")

plot_results(args...; kwargs...) = error("not implemented")
