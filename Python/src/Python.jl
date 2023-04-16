module Python
occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)

function _ensure_env!()
    "JULIA_CONDAPKG_ENV" ∉ keys(ENV) && setindex!(
        ENV, joinpath(dirname(Base.active_project()), ".conda"), "JULIA_CONDAPKG_ENV"
    )
end
_ensure_env!()

function _setup!()
    @eval begin
        "PYTHONPATH" ∈ keys(ENV) && pop!(ENV, "PYTHONPATH")
        using PythonCall.C.CondaPkg: envdir, add_pip, resolve

        # NOTE: Make sure conda libs precede system libs
        py_v[] = chomp(
            String(
                read(
                    `$(joinpath(envdir(), "bin", "python")) -c "import sys; print(str(sys.version_info.major) + '.' + str(sys.version_info.minor))"`,
                ),
            ),
        )
        const PYTHONPATH = ".:$(joinpath(envdir(), "lib"))/python$(py_v[])"
        setpypath!()
        using PythonCall:
            Py, pynew, pyimport, PyList, pyisnull, pycopy!, @py, pyconvert, pystr
    end
end

@doc "Remove wrong python version libraries dirs from python loading path."
function clearpypath!()
    if isempty(pymodpaths)
        append!(pymodpaths, pyconvert.(String, pyimport("sys").path))
    end
    ENV["PYTHONPATH"] = ".:$(envdir())/python$(py_v[])"

    sys_path_list = PyList(pyimport("sys")."path")
    empty!(sys_path_list)
    append!(sys_path_list, pystr.(pymodpaths))
end

setpypath!() = ENV["PYTHONPATH"] = PYTHONPATH

function isinitialized()
    _initialized[]
end

function __init__()
    _ensure_env!()
    isinitialized() && return nothing
    try
        clearpypath!()
        for f in callbacks
            f()
        end
        empty!(callbacks)
    catch e
        @debug e
    end
    _initialized[] = true
end

using SnoopPrecompile
using PythonCall: PyList, pynew, Py
using PythonCall.C.CondaPkg: envdir
const _initialized = Ref(false)
const callbacks = Function[]
const pymodpaths = String[]
const py_v = Ref("")
const pynull = pynew()

include("async.jl")
@precompile_all_calls begin
    _ensure_env!()
    _setup!()
    __init__()
    # NOTE: This should not be precompiled here, but only on the most upstream pkg
    # that imports python (e.g. Exchanges)
    # __init__()
    # _async_init(gpa)
end
_setup!()

@doc "Import a python module over a variable defined in global scope."
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

include("functions.jl")

# NOTE: This must be done after all the global code in this module has been execute
using Reexport
@reexport using PythonCall
export @pymodule, clearpypath!

end
