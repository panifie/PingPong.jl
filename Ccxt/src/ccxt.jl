using Python
using Misc: DATA_PATH
using Misc.ConcurrentCollections: ConcurrentDict
using Misc.Lang: @lget!
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

function _doinit()
    isinitialized() && return nothing
    if Python.isinitialized()
        _init()
    else
        push!(Python.CALLBACKS, _init)
    end
end

include("exchange_funcs.jl")

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

const FUNCTION_WRAPPERS = ConcurrentDict{UInt64,Function}()

# NOTE: watch_tickers([...]) returns empty sometimes...
# so call without args, and select the input
function choosefunc(exc, suffix, inputs::AbstractVector; kwargs...)
    @lget! FUNCTION_WRAPPERS hash((exc.id, suffix, inputs, kwargs...)) begin
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
                    out = Dict{eltype(inputs),Union{Tuple{Py,Task},Py}}()
                    try
                        for i in inputs
                            out[i] = pytask(f, Val(:fut), i; kwargs...)
                        end
                        for (i, (_, task)) in out
                            out[i] = fetch(task)
                        end
                        out
                    catch e
                        @sync for v in values(out)
                            v isa Tuple || continue
                            (fut, task) = v
                            istaskdone(task) || (pycancel(fut); (@async wait(task)))
                        end
                        e isa PyException && rethrow(e)
                        filter!(p -> p.second isa Tuple, out)
                    end
                end
            end
        else
            () -> pyfetch(f; kwargs...)
        end
    end
end

function choosefunc(exc, suffix, inputs...; kwargs...)
    choosefunc(exc, suffix, [inputs...]; kwargs...)
end

@doc "Upgrades the ccxt package."
function upgrade()
    @eval begin
        version = pyimport("ccxt").__version__
        using Python.PythonCall.C.CondaPkg: CondaPkg
        try
            CondaPkg.add_pip("ccxt"; version=">$version")
        catch
            # if the version is latest than we have to adjust
            # the version to GTE
            CondaPkg.add_pip("ccxt"; version=">=$version")
        end
    end
end
Python.pyimport("ccxt").__version__

export ccxt, ccxt_ws, ccxt_errors, ccxt_exchange, choosefunc
