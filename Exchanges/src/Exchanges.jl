module Exchanges
occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)

include("utils.jl")
include("exchanges.jl")
include("precompile.jl")

end # module Exchanges
