module Python
using PythonCall.C.CondaPkg: envdir, add_pip, resolve
# NOTE: Make sure conda libs precede system libs
const py_v = chomp(
    String(
        read(
            `$(joinpath(envdir(), "bin", "python")) -c "import sys; print(str(sys.version_info.major) + '.' + str(sys.version_info.minor))"`,
        ),
    ),
)
const PYTHONPATH = ".:$(joinpath(envdir(), "lib"))/python$(py_v)"
setpypath!() = ENV["PYTHONPATH"] = PYTHONPATH
setpypath!()
using PythonCall: Py, pynew, pyimport, PyList, pyisnull, pycopy!, @py, pyconvert, pystr
const pypaths = Vector{String}()

@doc "Remove wrong python version libraries dirs from python loading path."
function clearpypath!()
    isempty(pypaths) &&
        append!(pypaths, pyimport("sys").path |> x -> pyconvert(Vector{String}, x))
    ENV["PYTHONPATH"] = ".:$(envdir())/python$(py_v)"

    path_list = pyimport("sys")."path" |> PyList
    gpaths = [pystr(x) for x in pypaths]
    empty!(path_list)
    @py append!(path_list, gpaths)
end

function __init__()
    clearpypath!()
end
const pynull = pynew()


@doc "Import a python module over a variable defined in global scope."
macro pymodule(name, modname = nothing)
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

# NOTE: This must be done after all the global code in this module has been execute
using Reexport; @reexport using PythonCall
export @pymodule, clearpypath!
end
