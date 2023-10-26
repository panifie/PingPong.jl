using Executors: Executors as ect
using Executors.Strategies: Strategies as st, Strategy
using .ect.Instances
using .ect.OrderTypes
using Simulations
using Simulations.Processing: normalize!, resample
using Simulations: Statistics

using .st.Data
using .Data.DFUtils
using .Data.DataFramesMeta
using .Data.DataFrames

using .ect.TimeTicks
using .ect.Lang
using .Statistics
using .Statistics: median

__revise_mode__ = :eval
include("trades_resample.jl")
include("trades_balance.jl")
include("metrics.jl")
include("trades_metrics.jl")
