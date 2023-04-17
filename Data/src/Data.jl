module Data

if get(ENV, "JULIA_NOPRECOMP", "") == "all"
    __init__() = begin
        include(joinpath(@__DIR__, "data.jl"))
    end
else
    occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)
    include("data.jl")
    include("precompile.jl")
    function __init__()
        # @require Temporal = "a110ec8f-48c8-5d59-8f7e-f91bc4cc0c3d" include("ts.jl")
        Base.empty!(zcache)
        zi[] = ZarrInstance()
    end
end

end # module Data
