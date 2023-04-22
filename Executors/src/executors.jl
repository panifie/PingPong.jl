using TimeTicks
using Misc
using OrderTypes

include("context.jl")
include("checks.jl")
include("functions.jl")

include("orders/utils.jl")
include("orders/state.jl")
include("orders/limit.jl")
include("orders/market.jl")

pong!(args...; kwargs...) = error("Not implemented")
const execute! = pong!

struct UpdateOrders <: ExecAction end

export pong!, execute!, UpdateOrders
export limitorder,
    marketorder, filled, committed, isfilled, islastfill, isfirstfill, fullfill!, commit!
export queue!, cancel!
