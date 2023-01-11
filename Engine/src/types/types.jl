using Reexport

include("context.jl")
include("trades.jl")
include("instances.jl")
include("collections.jl")

for m in (:Trades, :Instances, :Collections)
    @eval @reexport using .$m
end
export Context
