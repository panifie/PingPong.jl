module Misc
include("lang.jl")
include("lists.jl")
include("types.jl")

using Distributed: @everywhere, workers, addprocs, rmprocs, RemoteChannel

ENV["JULIA_NUM_THREADS"] = Sys.CPU_THREADS

@doc "Holds recently evaluated statements."
const results = Dict{String,Any}()

const workers_setup = Ref(0)
function _find_module(sym)
    hasproperty(@__MODULE__, sym) && return getproperty(@__MODULE__, sym)
    hasproperty(Main, sym) && return getproperty(Main, sym)
    try
        return @eval (using $sym; $sym)
    catch
    end
    nothing
end

@doc "Instantiate new workers if the current number mismatches the requested one."
function _instantiate_workers(mod; force = false, num = 4)
    if workers_setup[] !== num || force
        length(workers()) > 1 && rmprocs(workers())

        m = _find_module(mod)
        exeflags = "--project=$(pkgdir(m))"
        addprocs(num; exeflags)

        @info "Instantiating $(length(workers())) workers."
        # Instantiate one at a time
        # to avoid possible duplicate parallel instantiations of CondaPkg
        c = RemoteChannel(1)
        put!(c, true)
        @eval @everywhere begin
            take!($c)
            using $mod
            put!($c, true)
        end
        workers_setup[] = num
    end
end

# insert_and_dedup!(v::Vector, x) = (splice!(v, searchsorted(v,x), [x]); v)

include("config.jl")

export results, config, resetconfig!, @as_td, timefloat

end
