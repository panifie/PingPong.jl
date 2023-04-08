module Backtest
occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)

using TimeTicks
using TimeTicks: TimeTicks as tt
using Misc
using Processing.Alignments
using Strategies: Strategy, ping!, reset!, WarmupPeriod
using Simulations: Simulations as sim
using OrderTypes
using Executors

include("trades.jl")
include("orders/limit.jl")
include("orders/pong.jl")
include("backtest.jl")

export backtest!

end
