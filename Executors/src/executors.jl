
using Strategies: Strategies
using Strategies.OrderTypes
using Strategies: Instances, Instruments
using Strategies.Misc
using .Misc.TimeTicks
using .Misc: Lang
using .Misc.DocStringExtensions

include("context.jl")
include("checks.jl")
include("functions.jl")

include("orders/iter.jl")
include("orders/utils.jl")
include("orders/state.jl")
include("orders/limit.jl")
include("orders/market.jl")

include("positions/utils.jl")
include("positions/state.jl")
include("positions/info.jl")

pong!(args...; kwargs...) = error("Not implemented")

@doc "(DEPRECATED) order updates are done internally now."
struct UpdateOrders <: ExecAction end # not impl
@doc "(DEPRECATED) The shuffled version of [`UpdateOrders`](@ref)."
struct UpdateOrdersShuffled <: ExecAction end
@doc "Action to cancel open orders."
struct CancelOrders <: ExecAction end
@doc "Action to update positions size."
struct UpdatePositions <: ExecAction end # not impl
@doc "Action to update leverage."
struct UpdateLeverage <: ExecAction end
@doc "Action to update margin mode."
struct UpdateMargin <: ExecAction end # not impl
@doc "Action executed after a new trade occurs."
struct NewTrade <: ExecAction end

@doc "Action to setup an OHLCV watcher."
struct WatchOHLCV <: ExecAction end
@doc "Action to update OHLCV data (from watchers)."
struct UpdateData <: ExecAction end
@doc "Action to initialize OHLCV data."
struct InitData <: ExecAction end

@doc "Action to setup an optimizer (context and params)."
struct OptSetup <: ExecAction end
@doc "Action run before a single simulation during optimization."
struct OptRun <: ExecAction end
@doc "Action to get the score of a single simulation (after it has finished)."
struct OptScore <: ExecAction end

export pong!, UpdateOrders, UpdateOrdersShuffled, CancelOrders
export UpdateLeverage, UpdateMargin, UpdatePositions
export OptSetup, OptRun, OptScore
export NewTrade
export WatchOHLCV, UpdateData, InitData
export limitorder, marketorder
export unfilled, committed, isfilled, islastfill, isfirstfill, trades, cost, feespaid
export queue!, cancel!, commit!
export hasorders
