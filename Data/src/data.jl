using Lang: @preset, @precomp
using DataStructures: DataStructures

include("utils.jl")
include("dictview.jl")
include("load.jl")
include("dataframes.jl")
include("series.jl")
include("cache.jl")

_doinit() = begin
    # @require Temporal = "a110ec8f-48c8-5d59-8f7e-f91bc4cc0c3d" include("ts.jl")
    Base.empty!(zcache)
    zi[] = ZarrInstance()
end
