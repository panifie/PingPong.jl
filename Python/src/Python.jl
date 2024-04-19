@doc """
Defines the Python module which sets up the Python interpreter and imports
required modules and constants.
"""
module Python

using PrecompileTools: @compile_workload
using DocStringExtensions

if get(ENV, "JULIA_NOPRECOMP", "") == "all"
    @eval __init__() = begin
        @eval begin
            include(joinpath(@__DIR__, "consts.jl"))
            include(joinpath(@__DIR__, "module.jl"))
            _setup!()
            _doinit()
        end
    end
else
    if occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", ""))
        __precompile__(false)
       include("consts.jl")
    end
    @compile_workload include("consts.jl")
    include("module.jl")
    __init__() = _doinit()
    @compile_workload include("precompile.jl")
    _setup!()
end
end
