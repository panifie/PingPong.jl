using PythonCall: pystr, Py, PyException, pyisstr, pyisnone, pyfloat
using PythonCall.GC: GC as PyGC
import PythonCall: PyDict

@doc """
    pylist_to_matrix(data::Py)

    Convert a Python list to a Julia matrix.
"""
function pylist_to_matrix(data::Py)
    permutedims(reduce(hcat, pyconvert(Vector{<:Vector}, data)))
end

@doc """
    @pystr(k, v=nothing)

    Convert a Julia value to a Python string representation.
"""
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

@doc """
    py_except_name(e::PyException)

    Get the name of a Python exception.
"""
function py_except_name(e::PyException)
    string(pygetattr(pytype(e), "__name__"))
end

@doc """
    pytofloat(v::Py, def::T)::T where {T<:Number}

    Convert a Python value to a Julia float, with a default value.
"""
function pytofloat(v::Py, def::T)::T where {T<:Number}
    if pyisinstance(v, pybuiltins.float)
        pyconvert(T, v)
    elseif pyisinstance(v, pybuiltins.str)
        isempty(v) ? zero(T) : pyconvert(T, pyfloat(v))
    else
        def
    end
end

@doc """
    pyisnonzero(v::Py)::Bool

    Check if a Python value is nonzero.
"""
function pyisnonzero(v::Py)::Bool
    if pyisnone(v)
        false
    elseif isnothing(pytryfloat(v))
        false
    else
        true
    end
end

@doc """
    PyDict(p::Pair)

    Create a Python dictionary from a pair.
"""
PyDict(p::Pair) = PyDict((p,))

@doc """
     pydicthash(d)

     Calculate the hash of a Python dictionary.
 """
pydicthash(d) =
    let h = zero(hash(0))
        try
            for v in d.values()
                if pyisvalue(v)
                    h = hash((h, v))
                end
            end
        catch
            return hash(h)
        end
        return h
    end

@doc "Test whether a Python object is a list."
islist(v) = v isa AbstractVector || pyisinstance(v, pybuiltins.list)
@doc "Test whether a Python object is a dictionary."
isdict(v) = v isa AbstractDict || pyisinstance(v, pybuiltins.dict)

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
            # if threadid() == 1
            #     Base.GC.gc(false)
            # end
            # Base.GC.enable(true)
            $(PyGC.enable)()
        end
    end
    esc(ex)
end

export @pystr, pytofloat, pyisnonzero, pydicthash, islist, isdict
