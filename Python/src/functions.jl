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

function pytofloat(v::Py, def::T)::T where {T<:Number}
    if pyisinstance(v, pybuiltins.float)
        pyconvert(T, v)
    elseif pyisinstance(v, pybuiltins.str)
        isempty(v) ? zero(T) : pyconvert(T, pyfloat(v))
    else
        def
    end
end

export @pystr, pytofloat
