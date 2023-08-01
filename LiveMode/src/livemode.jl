using PaperMode
using PaperMode.Executors
using .Executors: Strategies as st
using .Executors.Instances: Instances, Exchanges, Data, MarginInstance, NoMarginInstance
using .Exchanges
using .Exchanges: Python
using .st: Strategy, MarginStrategy, NoMarginStrategy, LiveStrategy
using PaperMode.OrderTypes
using PaperMode.Misc
using .Misc: Lang
using .Misc.TimeTicks
using .Lang: @deassert
using Base: SimpleLogger, with_logger

include("orders/limit.jl")
include("orders/pong.jl")
include("positions/utils.jl")
include("positions/pong.jl")
include("instances.jl")
include("balance.jl")
include("ccxt_orders.jl")

function live!(s::Strategy{Live}; throttle=Second(5), foreground=false)
end
