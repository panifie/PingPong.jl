module Ccxt

if get(ENV, "JULIA_NOPRECOMP", "") == "all"
    __init__() = begin
        include(joinpath(@__DIR__, "ccxt.jl"))
        @eval _doinit()
    end
else
    occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)
    include("ccxt.jl")
    __init__() = _doinit()
end

end # module Ccxt
