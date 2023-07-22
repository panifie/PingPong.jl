using Engine: Engine as egn
using Engine.Strategies: Strategies as st, Strategy
using .egn.Processing: normalize!, resample
using .egn.Instances
using .egn.OrderTypes
using .egn.Simulations

using .egn.Data
using .Data.DFUtils
using .Data.DataFramesMeta
using .Data.DataFrames

using .egn.TimeTicks
using .egn.Lang
using Statistics
using Statistics: median

__revise_mode__ = :eval
include("trades_resample.jl")
include("trades_balance.jl")
include("metrics.jl")
include("trades_metrics.jl")
