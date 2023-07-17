using PythonCall: pystr, Py, PyException

function pylist_to_matrix(data::Py)
    permutedims(reduce(hcat, pyconvert(Vector{<:Vector}, data)))
end

const pyCached = Dict{Any,Py}()
macro pystr(k)
    s = esc(k)
    :($__module__.@lget! $pyCached $s pystr($s))
end

function py_except_name(e::PyException)
    string(pygetattr(pytype(e), "__name__"))
end

export @pystr
