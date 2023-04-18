using Reexport
@reexport using DocStringExtensions
using JSON
using TimeTicks
using FunctionalCollections: PersistentHashMap

include("lists.jl")
include("types.jl")
include("config.jl")
include("helpers.jl")
include("parallel.jl")
include("ttl.jl")

@doc "Holds recently evaluated statements."
const results = Dict{String,Any}()

_doinit() = begin
    ENV["JULIA_NUM_THREADS"] = Sys.CPU_THREADS
    isdefined(Misc, :config) && empty!(config)
end

export results
