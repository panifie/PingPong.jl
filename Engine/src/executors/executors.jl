module Executors
using ..TimeTicks
using ..Misc
using ..Types
using ..Strategies: Strategy
using ..Engine: Engine

pong!(args...; kwargs...) = error("Not implemented")
const execute! = pong!

struct UpdateOrders <: ExecAction end

include("utils.jl")
include("backtest.jl")

export pong!, execute!, UpdateOrders

end
