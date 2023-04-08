module Executors
occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)

using TimeTicks
using Misc
using OrderTypes

include("context.jl")
include("checks.jl")
include("functions.jl")

include("orders/utils.jl")
include("orders/state.jl")
include("orders/limit.jl")

pong!(args...; kwargs...) = error("Not implemented")
const execute! = pong!

struct UpdateOrders <: ExecAction end

export pong!, execute!, UpdateOrders
export limitorder, filled, committed, isfilled, islastfill, isfirstfill, fullfill!

end
