module Misc

include("lists.jl")
include("types.jl")

using PythonCall.C.CondaPkg: envdir, add_pip
using Requires

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
const options = Dict{String, Any}()
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
                pycopy!($var_name, pyimport($str_mod))
            end
        end
        $var_name
    end
end

function resetoptions!()
    empty!(options)
    options["window"] = 7
    options["timeframe"] = "1d"
    options["quote"] = "USDT"
    options["margin"] = false
    options["min_vol"] = 10e4
    options["min_slope"] = 0.
    options["max_slope"] = 90.
end
resetoptions!()

macro margin!()
    :(options["margin"] = !options["margin"])
end

macro margin!!()
    :(options["margin"] = true)
end

setopt!(k, v) = setindex!(options, v, k)

@doc "Print a number."
function printn(n, cur="USDT"; precision=2, commas=true, kwargs...)
    println(format(n; precision, commas, kwargs...), " ", cur)
end

# insert_and_dedup!(v::Vector, x) = (splice!(v, searchsorted(v,x), [x]); v)

include("pbar.jl")

export printn, results, options, resetoptions!, setopt!, @as_td, @pyinit!

end
