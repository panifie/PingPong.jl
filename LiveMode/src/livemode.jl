using PaperMode
using PaperMode.Executors
using .Executors: Strategies as st
using .Executors.Instances: Instances, Exchanges, Data, MarginInstance, NoMarginInstance
using .Instances
using .Exchanges
using .Exchanges: Python
using .st: Strategy, MarginStrategy, NoMarginStrategy, LiveStrategy
using PaperMode.OrderTypes
using PaperMode.Misc
using .Misc: Lang, LittleDict
using .Misc.TimeTicks
using .Misc.Mocking: Mocking, @mock
using .Lang: @deassert
using Base: SimpleLogger, with_logger
import .Executors: pong!

include("utils.jl")
include("orders/utils.jl")
include("orders/limit.jl")
include("orders/pong.jl")
include("adhoc/utils.jl")
include("positions/utils.jl")
include("positions/pong.jl")
include("instances.jl")
include("balance.jl")
include("trades.jl")
include("ccxt_orders.jl")
include("watchers/positions.jl")
include("watchers/balance.jl")
# include("watchers/mytrades.jl")

function live!(s::Strategy{Live}; throttle=Second(5), foreground=false)
end
