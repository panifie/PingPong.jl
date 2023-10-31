using PythonCall: pynew, PyNULL, pyisbool
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
const PYREF = Ref{PythonAsync}()
isdefined(@__MODULE__, :gpa) || @eval const gpa = PythonAsync()
