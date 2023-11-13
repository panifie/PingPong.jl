module Python

using PrecompileTools: @compile_workload

if get(ENV, "JULIA_NOPRECOMP", "") == "all"
    @eval __init__() = begin
        @eval begin
            include(joinpath(@__DIR__, "python.jl"))
            include(joinpath(@__DIR__, "consts.jl"))
            _setup!()
            _doinit()
        end
    end
else
    occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)
    @compile_workload include("consts.jl")
    include("python.jl")
    __init__() = _doinit()
    @compile_workload include("precompile.jl")
    _setup!()
end
end
