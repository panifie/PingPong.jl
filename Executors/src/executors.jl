using TimeTicks
using Misc
using OrderTypes
using Strategies: Strategies

include("context.jl")
include("checks.jl")
include("functions.jl")

include("orders/utils.jl")
include("orders/state.jl")
include("orders/limit.jl")
include("orders/market.jl")

include("positions/utils.jl")
include("positions/state.jl")
include("positions/info.jl")

pong!(args...; kwargs...) = error("Not implemented")
const execute! = pong!

struct UpdateOrders <: ExecAction end
struct UpdateOrdersShuffled <: ExecAction end
struct CancelOrders <: ExecAction end
struct UpdatePositions <: ExecAction end
struct UpdateLeverage <: ExecAction end
struct UpdateMargin <: ExecAction end

struct OptSetup <:ExecAction end
struct OptRun <:ExecAction end
struct OptScore <:ExecAction end
struct OptGrid <:ExecAction end

export pong!, execute!, UpdateOrders, UpdateOrdersShuffled, CancelOrders
export UpdateLeverage, UpdateMargin, UpdatePositions
export OptSetup, OptRun, OptScore
export limitorder, marketorder
export unfilled, committed, isfilled, islastfill, isfirstfill, trades
export queue!, cancel!, commit!
export hasorders
