module Executors
using ..Types
using ..Strategies: Strategy
using ..Engine: Engine

const pong! = Returns(ErrorException("Not Implemented"))

const execute! = pong!

include("backtest.jl")

export pong!, execute!

end
