using Strategies: Strategies as st
using Simulations: Simulations as sim
using Processing.Alignments
using Executors

using Strategies: Strategy, ping!, reset!, WarmupPeriod
using OrderTypes
using OrderTypes: LimitOrderType, MarketOrderType
using TimeTicks
using TimeTicks: TimeTicks as tt
using Misc
using Lang: @deassert
using Base: negate

using Executors.Checks: cost, withfees
using Executors.Instances
using Executors.Instruments
import Executors: pong!

include("trades.jl")
include("orders/limit.jl")
include("orders/pong.jl")
include("orders/default.jl")
include("backtest.jl")

export backtest!
