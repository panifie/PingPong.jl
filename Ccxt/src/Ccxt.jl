module Ccxt
using Python
using Python: pynew, pycoro_type, pywait_fut, pyschedule
using Python.PythonCall: pyisnull, pycopy!
using Misc: DATA_PATH

function _init()
    async_init_task = @async Python._async_init()
    clearpypath!()
    if pyisnull(ccxt)
        @pymodule ccxt
        pycopy!(ccxt, pyimport("ccxt.async_support"))
        @pymodule ccxt_ws ccxt.pro
        (errors -> union(ccxt_errors, errors))(
            Set(string.(pydir(pyimport("ccxt.base.errors"))))
        )
        mkpath(joinpath(DATA_PATH, "markets"))
    end
    wait(async_init_task)
end

function __init__()
    if Python.initialized[]
        _init()
    else
        push!(Python.callbacks, _init)
    end
end

function close_exc(e::Py)
    @async if !pyisnull(e) && pyhasattr(e, "close")
        co = e.close()
        if !pyisnull(co) && pyisinstance(co, pycoro_type)
            wait(pytask(co, Val(:coro)))
        end
    end
end

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

using SnoopPrecompile
@precompile_setup begin
    const ccxt = pynew()
    const ccxt_ws = pynew()
    const ccxt_errors = Set{String}()
    @precompile_all_calls begin
        __init__()
        while pyisnull(ccxt_ws)
            sleep(0.001)
        end
    end
    @precompile_all_calls ccxt_exchange(:binance)
end

end # module Ccxt
