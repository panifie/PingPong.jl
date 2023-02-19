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

close_exc(e::Py) = !pyisnull(e) && pyhasattr(e, "close") && e.close()

_issupported(has::Py, k) = k in has && Bool(has[k])
issupported(exc, k) = _issupported(exc.py.has, k)

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
            () -> @sync begin
                out = Dict{eltype(inputs),Py}()
                for i in inputs
                    @async begin
                        out[i] = pyfetch(f, i; kwargs...)
                    end
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
