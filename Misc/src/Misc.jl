module Misc
using SnoopPrecompile
@precompile_setup @precompile_all_calls begin
    @eval using Reexport
    @eval @reexport using DocStringExtensions
end

include("docs.jl")
include("lists.jl")
include("types.jl")
include("config.jl")
include("helpers.jl")
include("parallel.jl")
include("ttl.jl")

@doc "Holds recently evaluated statements."
const results = Dict{String,Any}()

__init__() = begin
    ENV["JULIA_NUM_THREADS"] = Sys.CPU_THREADS
    empty!(config)
end

@precompile_setup @precompile_all_calls begin
    Dict{String,Any}()
    __init__()
end

export results

end
