module Data

include("utils.jl")
include("data.jl")
include("dataframes.jl")
include("lmdbstore.jl")
include("series.jl")

function __init__()
    @require Temporal = "a110ec8f-48c8-5d59-8f7e-f91bc4cc0c3d" include("ts.jl")
    zi[] = ZarrInstance()
end

using Reexport
@reexport using Zarr

end # module Data
