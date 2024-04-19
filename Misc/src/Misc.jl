module Misc

if get(ENV, "JULIA_NOPRECOMP", "") == "all"
    __init__() = begin
        include(joinpath(@__DIR__, "module.jl"))
        include(joinpath(@__DIR__, "consts.jl"))
        @eval _doinit()
    end
else
    if occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", ""))
        __precompile__(false)
        include("consts.jl")
    end
    include("module.jl")
    __init__() = _doinit()
    include("precompile.jl")
end


end
