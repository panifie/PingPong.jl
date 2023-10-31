using PythonCall: pystr, Py, PyException, pyisstr, pyisnone, pyfloat
import PythonCall: PyDict

function pylist_to_matrix(data::Py)
    permutedims(reduce(hcat, pyconvert(Vector{<:Vector}, data)))
end

macro pystr(k, v=nothing)
    s = esc(k)
    ev = if v isa Expr
        esc(v)
    else
        s
    end
    quote
        $__module__.@lget! $pyCached $s pystr($ev)
    end
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

function pyisnonzero(v::Py)::Bool
    if pyisnone(v)
        false
    elseif isnothing(pytryfloat(v))
        false
    else
        true
    end
end

PyDict(p::Pair) = PyDict((p,))

pydicthash(d) =
    let h = zero(hash(0))
        try
            for v in d.values()
                if pyisvalue(v)
                    h = hash((h, v))
                end
            end
        catch
        end
        return h
    end

export @pystr, @pystr, pytofloat, pyisnonzero, pydicthash
