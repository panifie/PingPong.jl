module Ccxt
using Python
using Python: pynew
using Python.PythonCall: pyisnull
using Misc: DATA_PATH

const ccxt = pynew()
const ccxt_ws = pynew()
const ccxt_errors = Set{String}()

function __init__()
    clearpypath!()
    if pyisnull(ccxt)
        @pymodule ccxt ccxt.async_support
        @pymodule ccxt_ws ccxt.pro
        (errors -> union(ccxt_errors, errors))(
            Set(string.(pydir(pyimport("ccxt.base.errors"))))
        )
        mkpath(joinpath(DATA_PATH, "markets"))
    end
end

close_exc(e::Py) = e.close()

@doc "Instantiate a ccxt exchange class matching name."
function ccxt_exchange(name::Symbol, params=nothing; kwargs...)
    @debug "Instantiating Exchange $name..."
    exc_cls =
        hasproperty(ccxt_ws, name) ? getproperty(ccxt_ws, name) : getproperty(ccxt, name)
    finalizer(close_exc, isnothing(params) ? exc_cls() : exc_cls(params))
end

@doc "Choose correct ccxt function according to what the exchange supports."
function _multifunc(exc, suffix, hasinputs=false)
    py = exc.py
    fname = "watch_" * suffix * "s"
    if hasproperty(py, fname)
        getproperty(py, fname), :multi
    elseif begin
        fname = "watch_" * suffix
        hasinputs && hasproperty(py, fname)
    end
        getproperty(py, fname), :single
    elseif begin
        fname = "fetch_" * suffix * "s"
        hasproperty(py, fname)
    end
        getproperty(py, fname), :multi
    else
        fname = "fetch_" * suffix
        @assert hasproperty(py, fname) "Exchange $(exc.name) does not support $name"
        @assert hasinputs "Single function needs inputs."
        getproperty(py, fname), :single
    end
end

# NOTE: watch_tickers([...]) returns empty sometimes...
# so call without args, and select the input
function choosefunc(exc, suffix, inputs::AbstractVector)
    hasinputs = length(inputs) > 0
    f, kind = _multifunc(exc, suffix, hasinputs)
    if hasinputs
        if kind == :multi
            () -> begin
                data = pyfetch(f)
                Dict(i => data[i] for i in inputs)
            end
        else
            () -> begin
                Dict(i => pyfetch(f, i) for i in inputs)
            end
        end
    else
        () -> begin
            pyfetch(f)
        end
    end
end

choosefunc(exc, suffix, inputs...) = choosefunc(exc, suffix, [inputs...])

export ccxt, ccxt_ws, ccxt_errors, ccxt_exchange, choosefunc
end # module Ccxt
