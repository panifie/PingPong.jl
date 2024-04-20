using Python
using Misc: DATA_PATH, Misc
using Misc.ConcurrentCollections: ConcurrentDict
using Misc.Lang: @lget!, Option
using Misc.DocStringExtensions
using Python: pynew, pyisnone, islist, isdict
using Python.PythonCall: pyisnull, pycopy!, pybuiltins
using Python: py_except_name

@doc "The ccxt python module reference"
const ccxt = Ref{Option{Py}}(nothing)
@doc "The ccxt.pro (websockets) python module reference"
const ccxt_ws = Ref{Option{Py}}(nothing)
@doc "Ccxt exception names"
const ccxt_errors = Set{String}()

@doc """ Checks if the ccxt object is initialized.

$(TYPEDSIGNATURES)

This function checks if the global variable `ccxt` is initialized by checking if it's not `nothing` and not `null` in the Python context.
"""
function isinitialized()
    val = ccxt[]
    !isnothing(val) && !pyisnull(val)
end

@doc """ Populates the `ccxt_errors` array with error names from the ccxt library.

$(TYPEDSIGNATURES)

This function checks if the `ccxt_errors` array is empty. If it is, it imports the `ccxt.base.errors` module from the ccxt library, retrieves the directory of the module, and iterates over each error. It then checks if the first character of the error name is uppercase. If it is, the error name is added to the `ccxt_errors` array.
"""
function _ccxt_errors!()
    if isempty(ccxt_errors)
        for err in pyimport("ccxt.base.errors") |> pydir
            name = string(err)
            if isuppercase(first(name))
                push!(ccxt_errors, name)
            end
        end
    end
end

@doc """ Determines if a Python exception is a ccxt error.

$(TYPEDSIGNATURES)
"""
function isccxterror(err::PyException)
    _ccxt_errors!()
    py_except_name(err) ∈ ccxt_errors
end
@doc " The path to the markets data directory."
const MARKETS_PATH = joinpath(DATA_PATH, "markets")

@doc """ Initializes the Python environment and creates the markets data directory.

$(TYPEDSIGNATURES)
"""
function _init()
    clearpypath!()
    if !isinitialized()
        try
            Python._async_init(Python.PythonAsync())
            mkpath(MARKETS_PATH)
            if ccall(:jl_generating_output, Cint, ()) != 0
                Python.py_stop_loop()
            end
        catch e
            @error e Python.PY_V ENV["PYTHONPATH"] syspath = pyimport("sys").path vinfo =
                pyimport("sys").version_info
        end
    end
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
    fname = "fetch" * suffix * "sWs"
    if issupported(exc, fname) || begin
        fname = "fetch" * suffix * "s"
        issupported(exc, fname)
    end
        getproperty(py, fname), :multi
    else
        fname = "fetch" * suffix * "Ws"
        if !issupported(exc, fname)
            fname = "fetch" * suffix
        end
        @assert issupported(exc, fname) "Exchange $(exc.name) does not support $fname"
        @assert hasinputs "Single function needs inputs."
        getproperty(py, fname), :single
    end
end

@doc """
A dictionary for storing function wrappers with their unique identifiers.
"""
function _out_as_input(inputs, data; elkey=nothing)
    if islist(data)
        if length(data) == length(inputs)
            Dict(i => v for (v, i) in zip(data, inputs))
        else
            @assert !isnothing(elkey) "Functions returned a list, but element key not provided."
            Dict(v[elkey] => v for v in data)
        end
    elseif isdict(data)
        Dict(i => data[i] for i in inputs if haskey(data, i))
    else
        Dict(i => data for i in inputs)
    end
end

# NOTE: watch_tickers([...]) returns empty sometimes...
# so call without args, and select the input
@doc """ Chooses a function based on the provided parameters and executes it.

$(TYPEDSIGNATURES)

This function selects a function based on the provided exception, suffix, and inputs. It then executes the chosen function with the provided inputs and keyword arguments. The function can handle multiple types of inputs and can execute multiple functions concurrently if necessary.
"""
function choosefunc(exc, suffix, inputs::AbstractVector; elkey=nothing, kwargs...)
    hasinputs = length(inputs) > 0
    f, kind = _multifunc(exc, suffix, hasinputs)
    if hasinputs
        if kind == :multi
            function multi_func()
                args = isempty(inputs) ? () : (inputs,)
                data = pyfetch(f, args...; kwargs...)
                _out_as_input(inputs, data; elkey)
            end
        else
            function single_func()
                out = Dict{eltype(inputs),Union{Task,Py}}()
                try
                    for i in inputs
                        out[i] = pytask(f(i); kwargs...)
                    end
                    for (i, task) in out
                        out[i] = fetch(task)
                    end
                catch e
                    @sync for v in values(out)
                        if v isa Task && !istaskdone(v)
                            pycancel(v)
                        end
                    end
                    e isa PyException && rethrow(e)
                    filter!(p -> p isa Task, out)
                end
                _out_as_input(inputs, out; elkey)
            end
        end
    else
        args = isempty(inputs) ? () : (inputs,)
        default_func() = pyfetch(f, args...; kwargs...)
    end
end

function choosefunc(exc, suffix, inputs...; kwargs...)
    choosefunc(exc, suffix, [inputs...]; kwargs...)
end

@doc """ Upgrades the ccxt library to the latest version.

$(TYPEDSIGNATURES)

This function upgrades the ccxt library to the latest version available. It checks the current version of the ccxt library, and if a newer version is available, it upgrades the library using pip.
"""
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
    Python.pyimport("ccxt").__version__
end

export ccxt, ccxt_ws, isccxterror, ccxt_exchange, choosefunc
