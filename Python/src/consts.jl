using PythonCall: pynew, PyNULL, Py
using PythonCall.Core: pyisbool, pyisTrue

@doc "This constant indicates whether the Python runtime has been initialized. It is used to delay initialization until the first Python call."
const _INITIALIZED = Ref(false)

@doc "An array of callback functions."
const CALLBACKS = Function[]

@doc "An array of Python module paths."
const PYMODPATHS = String[]

@doc "The Python module search path."
const PYTHONPATH = Ref("")

@doc "The Python version."
const PY_V = Ref("")

@doc "A Python object used for converting values to float."
const pytryfloat = pynew()

@doc "A Python object used for checking if a value is a Python object."
const pyisvalue_func = pynew()

@doc "A dictionary for caching Python objects."
const pyCached = Dict{Any,Py}()

# async
@doc """A structure for handling Python's asynchronous operations.

$(FIELDS)

This structure is used to manage Python's asynchronous operations. It contains fields for Python's asyncio, threads, event loop, coroutine type, global variables, start function, and task status.
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

const GC_TASK = Ref{Task}()
const GC_RUNNING = Ref(false)
