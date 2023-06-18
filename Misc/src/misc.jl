using Reexport
@reexport using DocStringExtensions
using JSON
using TimeTicks
using TimeTicks: Lang
using FunctionalCollections: PersistentHashMap
using ConcurrentCollections: ConcurrentCollections
using OrderedCollections: OrderedCollections, OrderedDict, LittleDict

include("lists.jl")
include("sandbox.jl")
include("types.jl")
include("config.jl")
include("helpers.jl")
include("parallel.jl")
include("ttl.jl")

@doc "Holds recently evaluated statements."
const results = Dict{String,Any}()

_doinit() = begin
    ENV["JULIA_NUM_THREADS"] = Sys.CPU_THREADS
    isdefined(Misc, :config) && reset!(config)
end

export results
