module Executors
using ..Types
using ..Strategies: Strategy
using ..Engine: Engine

pong!(s::Strategy, ctx, args...; kwargs...) = error("Not Implemented")

const execute! = pong!

include("backtest.jl")

export pong!, execute!

end
