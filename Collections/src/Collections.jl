@doc """ =Collections= module
"""
module Collections

if get(ENV, "JULIA_NOPRECOMP", "") == "all"
    __init__() = begin
        include(joinpath(@__DIR__, "collections.jl"))
    end
else
    occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)
    include("collections.jl")
end

end
