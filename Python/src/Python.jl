module Python

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
    include("python.jl")
    __init__() = _doinit()
    include("precompile.jl")
    _setup!()
end
end
