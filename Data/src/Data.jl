module Data
occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)

using Lang: @preset, @precomp
using DataStructures: DataStructures
include("utils.jl")
include("dictview.jl")
include("data.jl")
include("dataframes.jl")
include("series.jl")
include("cache.jl")

function __init__()
    # @require Temporal = "a110ec8f-48c8-5d59-8f7e-f91bc4cc0c3d" include("ts.jl")
    # zi[] = zilmdb()
end

include("precompile.jl")

end # module Data
