using Makie
using Stats
using Stats: egn
using Makie: parent_scene, shift_project, update_tooltip_alignment!, Figure
using .egn.Misc
using .egn.TimeTicks
using .egn.Lang

include("utils.jl")
include("ohlcv.jl")
include("trades.jl")
include("inds.jl")
include("opt.jl")
