module Misc

include("lists.jl")
include("types.jl")

using Conda: pip, LIBDIR, BINDIR

# NOTE: Make sure conda libs precede system libs
py_v = chomp(String(read(`$(joinpath(BINDIR, "python")) -c "import sys; print(str(sys.version_info.major) + '.' + str(sys.version_info.minor))"`)))
ENV["PYTHONPATH"] = ".:$(LIBDIR)/python$(py_v)"
ENV["JULIA_NUM_THREADS"] = Sys.CPU_THREADS

using PyCall: PyObject, PyNULL, pyimport

const pynull = PyNULL()
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
    pynull = PyNULL()
    quote
        @eval begin
            isdefined($__module__, Symbol($str_name)) || const $name = Ref($pynull)
        end
        if $var_name == $pynull
            try
                copy!($var_name, pyimport($str_mod))
            catch
                pip("install", $str_mod)
                copy!($var_name, pyimport($str_mod))
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

export printn, results, options, resetoptions!, setopt!, @as_td

end
