module Ccxt

using Python
using Misc: DATA_PATH
using Python: pynew
using Python.PythonCall: pyisnull, pycopy!

const ccxt = Ref{Union{Nothing,Py}}(nothing)
const ccxt_ws = Ref{Union{Nothing,Py}}(nothing)
const ccxt_errors = Set{String}()

function isinitialized()
    !isnothing(ccxt[]) && !pyisnull(ccxt[])
end

function _init()
    clearpypath!()
    if isnothing(ccxt[]) || pyisnull(ccxt[])
        pyimport("ccxt")
        ccxt[] = pyimport("ccxt.async_support")
        ccxt_ws[] = pyimport("ccxt.pro")
        (errors -> union(ccxt_errors, errors))(
            Set(string.(pydir(pyimport("ccxt.base.errors"))))
        )
        mkpath(joinpath(DATA_PATH, "markets"))
    end
    Python._async_init(Python.PythonAsync())
end

function __init__()
    isinitialized() && return nothing
    if Python.isinitialized()
        _init()
    else
        push!(Python.callbacks, _init)
    end
end

include("exchange_funcs.jl")
# There isn't anything worth precompiling here
# we can't precompile init functions because python runtime
# using SnoopPrecompile
# @precompile_setup begin
#     @precompile_all_calls begin
#         __init__()
#         ccxt_exchange(:binance)
#     end
# end

@doc "Choose correct ccxt function according to what the exchange supports."
function _multifunc(exc, suffix, hasinputs=false)
    py = exc.py
    fname = "watch" * suffix * "s"
    if issupported(exc, fname)
        getproperty(py, fname), :multi
    elseif begin
        fname = "watch" * suffix
        hasinputs && issupported(exc, fname)
    end
        getproperty(py, fname), :single
    elseif begin
        fname = "fetch" * suffix * "s"
        issupported(exc, fname)
    end
        getproperty(py, fname), :multi
    else
        fname = "fetch" * suffix
        @assert issupported(exc, fname) "Exchange $(exc.name) does not support $fname"
        @assert hasinputs "Single function needs inputs."
        getproperty(py, fname), :single
    end
end

# NOTE: watch_tickers([...]) returns empty sometimes...
# so call without args, and select the input
function choosefunc(exc, suffix, inputs::AbstractVector; kwargs...)
    hasinputs = length(inputs) > 0
    f, kind = _multifunc(exc, suffix, hasinputs)
    if hasinputs
        if kind == :multi
            () -> begin
                data = pyfetch(f; kwargs...)
                Dict(i => data[i] for i in inputs)
            end
        else
            () -> begin
                out = Dict{eltype(inputs),Union{Task,Py}}()
                for i in inputs
                    out[i] = pytask(f, i; kwargs...)
                end
                for (i, task) in out
                    out[i] = fetch(task)
                end
                out
            end
        end
    else
        () -> pyfetch(f; kwargs...)
    end
end

function choosefunc(exc, suffix, inputs...; kwargs...)
    choosefunc(exc, suffix, [inputs...]; kwargs...)
end

export ccxt, ccxt_ws, ccxt_errors, ccxt_exchange, choosefunc

end # module Ccxt
