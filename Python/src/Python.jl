module Python

if get(ENV, "JULIA_NOPRECOMP", "") == "all"
    __init__() = begin
        include(joinpath(@__DIR__, "python.jl"))
        @eval begin
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
