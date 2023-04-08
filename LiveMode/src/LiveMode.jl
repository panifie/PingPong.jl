module LiveMode
occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)

include("orders.jl")
include("instances.jl")
include("balance.jl")

end # module LiveMode
