using PythonCall: pynew, PyNULL, pyisbool, Py
const _INITIALIZED = Ref(false)
const CALLBACKS = Function[]
const PYMODPATHS = String[]
const PYTHONPATH = Ref("")
const PY_V = Ref("")
const pytryfloat = pynew()
const pyisvalue_func = pynew()
# functions
const pyCached = Dict{Any,Py}()

# async
"""
    PythonAsync(;pyaio::Py = pynew(), pyuv::Py = pynew(), pythreads::Py = pynew(), pyrunner::Py = pynew(), pyloop::Py = pynew(), pycoro_type::Py = pynew(), task::Ref{Task} = Ref{Task}())

A structure that holds references to the Python asynchronous objects and state.
"""
@kwdef struct PythonAsync
    pyaio::Py = pynew()
    pythreads::Py = pynew()
    pyloop::Py = pynew()
    pycoro_type::Py = pynew()
    globs::Py = pynew()
    start_func::Py = pynew()
    task::Ref{Task} = Ref{Task}()
    task_running::Ref{Bool} = Ref(false)
end

const PYREF = Ref{PythonAsync}()
isdefined(@__MODULE__, :gpa) || @eval const gpa = PythonAsync()
