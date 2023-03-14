module Misc

include("lists.jl")
include("types.jl")
include("config.jl")
include("helpers.jl")
include("parallel.jl")

@doc "Holds recently evaluated statements."
const results = Dict{String,Any}()

__init__() = begin
    ENV["JULIA_NUM_THREADS"] = Sys.CPU_THREADS
end

export results

end
