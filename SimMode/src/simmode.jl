using Strategies: Strategies as st
using Simulations: Simulations as sim
using Processing.Alignments
using Executors

using Strategies: Strategy, ping!, WarmupPeriod
using OrderTypes
using OrderTypes: LimitOrderType, MarketOrderType
using TimeTicks
using TimeTicks: TimeTicks as tt
using Misc
using Lang: @deassert, @ifdebug
using Base: negate

using Executors.Checks: cost, withfees
using Executors.Instances
using Executors.Instances: getexchange!
using Executors.Instruments
using Executors.Instruments: @importcash!
import Executors: pong!
@importcash!

include("trades.jl")
include("orders/utils.jl")
include("orders/limit.jl")
include("orders/market.jl")
include("orders/pong.jl")
include("positions/utils.jl")
include("positions/ping.jl")
include("positions/pong.jl")
include("backtest.jl")
@ifdebug include("debug.jl")

export backtest!
