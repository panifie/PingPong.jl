using SnoopPrecompile
using PythonCall: PyList, pynew, Py
using PythonCall.C.CondaPkg: envdir
const _INITIALIZED = Ref(false)
const CALLBACKS = Function[]
const PYMODPATHS = String[]
const PYTHONPATH = Ref("")
const PY_V = Ref("")
const pynull = pynew()
const pytryfloat = pynew()

setpypath!() =
    if length(PYTHONPATH[]) > 0
        ENV["PYTHONPATH"] = PYTHONPATH[]
    elseif "PYTHONPATH" ∈ keys(ENV)
        pop!(ENV, "PYTHONPATH")
    end

function _ensure_env!()
    "JULIA_CONDAPKG_ENV" ∉ keys(ENV) && setindex!(
        ENV, joinpath(dirname(Base.active_project()), ".conda"), "JULIA_CONDAPKG_ENV"
    )
    setpypath!()
end

function _setup!()
    @eval begin
        using PythonCall.C.CondaPkg: envdir, add_pip, resolve

        # NOTE: Make sure conda libs precede system libs
        PY_V[] = chomp(
            String(
                read(
                    `$(joinpath(envdir(), "bin", "python")) -c "import sys; print(str(sys.version_info.major) + '.' + str(sys.version_info.minor))"`,
                ),
            ),
        )
        PYTHONPATH[] = ".:$(joinpath(envdir(), "lib"))/python$(PY_V[])"
        setpypath!()
        using PythonCall:
            Py, pynew, pyimport, PyList, pyisnull, pycopy!, @py, pyconvert, pystr
        _ensure_env!()
    end
end

@doc "Remove wrong python version libraries dirs from python loading path."
function clearpypath!()
    if isempty(PYMODPATHS)
        append!(PYMODPATHS, pyconvert.(String, pyimport("sys").path))
    end
    ENV["PYTHONPATH"] = ".:$(envdir())/python$(PY_V[])"

    sys_path_list = PyList(pyimport("sys")."path")
    empty!(sys_path_list)
    append!(sys_path_list, pystr.(PYMODPATHS))
end

function isinitialized()
    _INITIALIZED[]
end

function _doinit()
    _ensure_env!()
    isinitialized() && return nothing
    try
        clearpypath!()
        for f in CALLBACKS
            f()
        end
        empty!(CALLBACKS)
        _pytryfloat_func!()
    catch e
        @debug e
    end
    _INITIALIZED[] = true
end

function _pytryfloat_func!(force=false)
    pyisnull(pytryfloat) ||
        force && begin
            code = """
            def tryfloat(v):
                try:
                    return float(v)
                except:
                    pass
            """
            func = pyexec(NamedTuple{(:tryfloat,),Tuple{Py}}, code, pydict()).tryfloat
            pycopy!(pytryfloat, func)
        end
end

include("async.jl")

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
export @pymodule, clearpypath!, pytryfloat
