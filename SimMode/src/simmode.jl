using Executors
using Executors: Misc
using Executors: Strategies, Strategies as st
using Simulations: Simulations as sim
using Simulations.Processing.Alignments

using .Strategies: Strategy, ping!, WarmupPeriod, OrderTypes
using .OrderTypes
using .OrderTypes: LimitOrderType, MarketOrderType
using .Misc
using .Misc.TimeTicks
using .TimeTicks: TimeTicks as tt
using .Misc.Lang: Lang, @deassert, @ifdebug
using Base: negate

using Executors.Checks: cost, withfees
using Executors.Instances
using Executors.Instances: getexchange!
using Executors.Instruments
using Executors.Instruments: @importcash!
using Executors: attr
import Executors: pong!
@importcash!

include("trades.jl")
include("orders/utils.jl")
include("orders/limit.jl")
include("orders/market.jl")
include("orders/pong.jl")
include("orders/updates.jl")

include("positions/utils.jl")
include("positions/ping.jl")
include("positions/pong.jl")

include("backtest.jl")
include("pong.jl")
@ifdebug include("debug.jl")

export start!
