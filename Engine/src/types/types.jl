using Reexport

include("context.jl")
include("trades.jl")
include("instances.jl")
include("collections.jl")
include("strategies.jl")

for m in (:Trades, :Instances, :Collections, :Strategies)
    @eval @reexport using .$m
end
export Context
