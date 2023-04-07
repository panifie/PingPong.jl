module Misc

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

export results

end
