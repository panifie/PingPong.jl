module PaperMode

if get(ENV, "JULIA_NOPRECOMP", "") == "all"
    __init__() = begin
        include(joinpath(@__DIR__, "papermode.jl"))
    end
else
    occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)
    include("papermode.jl")
    if occursin(string(@__MODULE__), get(ENV, "JULIA_PRECOMP", ""))
        include("precompile.jl")
    end
end

end # module PaperMode
