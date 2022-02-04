module Misc

include("lists.jl")
include("types.jl")

using PythonCall.C.CondaPkg: envdir, add_pip, resolve
using Requires
using Distributed: @everywhere, workers, addprocs, rmprocs, RemoteChannel

# NOTE: Make sure conda libs precede system libs
const py_v = chomp(String(read(`$(joinpath(envdir(), "bin", "python")) -c "import sys; print(str(sys.version_info.major) + '.' + str(sys.version_info.minor))"`)))
ENV["JULIA_NUM_THREADS"] = Sys.CPU_THREADS
ENV["PYTHONPATH"] = ".:$(joinpath(envdir(), "lib"))/python$(py_v)"
using PythonCall: Py, pynew, pyimport, PyVector, pyisnull, pycopy!
const pypaths = pyimport("sys").path


@doc "Remove wrong python version libraries dirs from python loading path."
function pypath!()
    ENV["PYTHONPATH"] = ".:$(LIBDIR)/python$(py_v)"
    path_list = pyimport("sys")."path" |> PyVector
    empty!(path_list)
    append!(path_list, pypaths)
end

const pynull = pynew()
const results = Dict{String, Any}()

macro ifundef(name, val, mod=__module__)
    name_var = esc(name)
    name_sym = esc(:(Symbol($(string(name)))))
    quote
        if isdefined($mod, $name_sym)
            $name_var = getproperty($mod, $name_sym)
        else
            $name_var = $val
        end
    end
end

macro pymodule(name, modname=nothing)
    str_name = string(name)
    str_mod = isnothing(modname) ? str_name : string(modname)
    var_name = esc(name)
    quote
        @assert isdefined($__module__, Symbol($str_name)) "Var name given for pyimport not found in module scope."
        if $pyisnull($var_name)
            try
                pycopy!($var_name, pyimport($str_mod))
            catch
                add_pip($str_mod)
                resolve()
                pycopy!($var_name, pyimport($str_mod))
            end
        end
        $var_name
    end
end

@doc "Print a number."
function printn(n, cur="USDT"; precision=2, commas=true, kwargs...)
    println(format(n; precision, commas, kwargs...), " ", cur)
end

const workers_setup = Ref(0)
# @everywhere push!(LOAD_PATH, $())
#
function _find_module(sym)
    hasproperty(@__MODULE__, sym) && return getproperty(@__MODULE__, sym)
    hasproperty(Main, sym) && return getproperty(Main, sym)
    try return @eval (using $sym; $sym) catch end
    nothing
end

@doc "Instantiate new workers if the current number mismatches the requested one."
function _instantiate_workers(mod; force=false, num=4)
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
include("pbar.jl")

export printn, results, config, resetconfig!, setopt!, @as_td, @pyinit!

end
