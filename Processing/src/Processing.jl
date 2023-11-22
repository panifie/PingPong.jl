@doc """ Module for data resampling, cleaning, aligning, etc.

"""
module Processing

if get(ENV, "JULIA_NOPRECOMP", "") == "all"
    __init__() = begin
        include(joinpath(@__DIR__, "processing.jl"))
    end
else
    occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)
    include("processing.jl")
    include("precompile.jl")
end


end # module Processing
