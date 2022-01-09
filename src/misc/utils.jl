module Misc

include("types.jl")

using PyCall: PyObject

ENV["JULIA_NUM_THREADS"] = Sys.CPU_THREADS
const pynone = PyObject(nothing)
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

function resetoptions!()
    empty!(options)
    options["window"] = 7
    options["timeframe"] = "1d"
    options["quote"] = "USDT"
    options["min_vol"] = 10e4
    options["min_slope"] = 0.
    options["max_slope"] = 90.
end
resetoptions!()

setopt!(k, v) = setindex!(options, v, k)

@doc "Print a number."
function printn(n, cur="USDT"; precision=2, commas=true, kwargs...)
    println(format(n; precision, commas, kwargs...), " ", cur)
end

# insert_and_dedup!(v::Vector, x) = (splice!(v, searchsorted(v,x), [x]); v)

export printn, results, options, resetoptions!, setopt!, @as_td

end
