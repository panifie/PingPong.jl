module Scrapers

using Lang: SnoopPrecompile, @preset, @precomp

if get(ENV, "JULIA_NOPRECOMP", "") == "all"
    __init__() = begin
        include(joinpath(@__DIR__, "scrapers.jl"))
        @eval _doinit()
    end
else
    occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)
    @precomp begin
        include("scrapers.jl")
        __init__() = _doinit()
        include("precompile.jl")
    end
end

end # module Scrapers
