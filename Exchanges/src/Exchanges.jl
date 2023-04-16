module Exchanges

if get(ENV, "JULIA_NOPRECOMP", "") == "all"
    __init__() = begin
        include(joinpath(@__DIR__, "exchanges.jl"))
    end
else
    occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)
    include("exchanges.jl")
    include("precompile.jl")
    __init__() = nothing
end

end # module Exchanges
