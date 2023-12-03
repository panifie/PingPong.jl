module Fetch

if get(ENV, "JULIA_NOPRECOMP", "") == "all"
    __init__() = begin
        include(joinpath(@__DIR__, "fetch.jl"))
    end
else
    occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)
    include("fetch.jl")
    if occursin(string(@__MODULE__), get(ENV, "JULIA_PRECOMP", ""))
        include("precompile.jl")
    end
end

end
