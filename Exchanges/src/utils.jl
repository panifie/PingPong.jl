using Python
using Python.PythonCall: pyisnone, pystr

const pyCached = Dict{String,Py}()
macro pystr(k)
    s = esc(k)
    :(@lget! pyCached $s pystr($s))
end
