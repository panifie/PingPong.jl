module ExchangeTypes

if get(ENV, "JULIA_NOPRECOMP", "") == "all"
    __init__() = begin
        include(joinpath(@__DIR__, "module.jl"))
        @eval _doinit()
    end
else
    occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)
    include("module.jl")
    __init__() = _doinit()
    include("precompile.jl")
end

end # module ExchangeTypes
