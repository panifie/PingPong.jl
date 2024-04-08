using PythonCall: PyList, pynew, Py
# using PythonCall.C.CondaPkg: envdir
using PythonCall.GC: GC as PyGC

@doc """ Disables pythoncall gc calls during the execution of an expression.

$(TYPEDSIGNATURES)

This macro takes an expression and ensures that the pythoncall garbage collector is disabled during its execution.
The garbage collector is re-enabled after the expression has been executed, regardless of whether the expression completed successfully or an error was thrown.
"""
macro nogc(expr)
    ex = quote
        try
            $(PyGC.disable)()
            # Base.GC.enable(false)
            $expr
        finally
            # if Threads.threadid() == 1
            #     Base.GC.gc(false)
            # end
            # Base.GC.enable(true)
            $(PyGC.enable)()
        end
    end
    esc(ex)
end

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
    if @something tryparse(Bool, get(ENV, "PINGPONG_OFFLINE", "")) false
        ENV["JULIA_CONDAPKG_OFFLINE"] = true
    end
    setpypath!()
end

function _setup!()
    # isprecomp = ccall(:jl_generating_output, Cint, ()) != 0
    @eval let
        using PythonCall.C.CondaPkg: envdir, add_pip, resolve

        # PY_V[] = chomp(
        #     String(
        #         read(
        #             `$(joinpath(envdir(), "bin", "python")) -c "import sys; print(str(sys.version_info.major) + '.' + str(sys.version_info.minor))"`,
        #         ),
        #     ),
        # )
        PY_V[] = let vinfo = pyimport("sys").version_info
            string(vinfo.major, ".", vinfo.minor)
        end
        # NOTE: Make sure conda libs precede system libs
        PYTHONPATH[] = string(".:", joinpath(envdir(), "lib"), "/python", PY_V[])
        setpypath!()
        using PythonCall:
            Py, pynew, pyimport, PyList, pyisnull, pycopy!, @py, pyconvert, pystr
        _ensure_env!()
        _INITIALIZED[] = false
    end
end

@doc "Remove wrong python version libraries dirs from python loading path."
function clearpypath!()
    sys_path_list = PyList(pyimport("sys").path)
    ENV["PYTHONPATH"] = ".:$(envdir())/python$(PY_V[])"
    if isempty(PYMODPATHS)
        append!(PYMODPATHS, (pyconvert(String, p) for p in sys_path_list))
    else
        empty!(sys_path_list)
        append!(sys_path_list, (pystr(p) for p in PYMODPATHS))
    end
end

function pygctask!()
    if ccall(:jl_generating_output, Cint, ()) != 0
        return nothing
    end
    GC_TASK[] = @async begin
        GC_RUNNING[] = true
        while GC_RUNNING[]
            try
                if Threads.threadid() == 1
                    PyGC.enable()
                    PyGC.disable()
                end
            catch e
                @error exception = e
            end
            sleep(1)
        end
    end
end

function isinitialized()
    _INITIALIZED[]
end

function _doinit()
    _ensure_env!()
    isinitialized() && return nothing
    try
        clearpypath!()
        _pytryfloat_func!()
        _pyisvalue_func!()
        for f in CALLBACKS
            f()
        end
        empty!(CALLBACKS)
        pygctask!()
    catch e
        @debug e
    end
    _INITIALIZED[] = true
end

function _pytryfloat_func!(force=false)
    (pyisnull(pytryfloat) || force) && begin
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

function _pyisvalue_func!(force=false)
    (pyisnull(pyisvalue_func) || force) && begin
        code = """
        global value_type
        value_type = (str, bool, int, float, type(None))
        def isvalue(v):
            try:
                return isinstance(v, value_type)
            except:
                false
        """
        func = pyexec(NamedTuple{(:isvalue,),Tuple{Py}}, code, pydict()).isvalue
        pycopy!(pyisvalue_func, func)
    end
end
pyisvalue(v) =
    if pyisnull(pyisvalue_func)
        false
    else
        pyisvalue_func(v) |> pyisTrue
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
                $add_pip($str_mod)
                $resolve()
                pycopy!($var_name, pyimport($str_mod))
            end
        end
        $var_name
    end
end

include("functions.jl")
using Reexport
# NOTE: This must be done after all the global code in this module has been execute
@reexport using PythonCall
export @pymodule, clearpypath!, pytryfloat
